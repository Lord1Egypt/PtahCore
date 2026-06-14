// store — ASYNC drain engine, TMEM slot → gmem. Twin: pymodel/store.py.
//
// One fp32 element per cycle from the array's drain port. The drain
// return is a REGISTER PIPELINE — the grid's south-boundary register
// (mac_grid.sv) plus, at chip level, the launch and capture registers
// of the clk_s tap (CHIP_SPEC §2) — so drain_data answers the
// drain_idx of DRAIN_LAT cycles ago: the engine runs a request stage
// (idx 0..ELEMS-1) and a write-back stage DRAIN_LAT behind it.
// At each drain-row change (every N elements, and at burst start) the
// engine inserts ONE settle bubble so the grid's southbound chain is a
// settled bus before its first capture (ARRAY_SPEC §3) — M extra
// cycles per burst. dtype=0 writes 4-byte fp32; dtype=1 converts
// through fp8_encode (RNE, saturating e4m3), 1 byte.
//
// PtahCore's flagship ISA improvement: completion is a barrier arrival
// (done pulse), never a front-end stall — epilogue overlap is free.

`default_nettype none

module store #(
    parameter int M = 32,
    parameter int N = 32,
    parameter int SLOT_W = 2,
    parameter int GMEM_AW = 32,
    parameter int DRAIN_LAT = 1     // request → drain_data, cycles
) (
    input  wire                clk,
    input  wire                rst,

    input  wire                start,
    input  wire [3:0]          start_bar,
    input  wire [GMEM_AW-1:0]  start_gmem,
    input  wire [SLOT_W-1:0]   start_slot,
    input  wire                start_dtype,     // 0 = fp32, 1 = fp8 e4m3

    output logic               busy,
    output logic               done,            // 1-cycle pulse
    output logic [3:0]         done_bar,

    // drain port into the array (registered data return, 1 cycle)
    output logic [SLOT_W-1:0]  drain_slot,
    output logic [$clog2(M*N)-1:0] drain_idx,
    input  wire  [31:0]        drain_data,

    // MXFP8 scale lookup (Phase 8). drain_data answers wr_idx_q (the index
    // requested DRAIN_LAT cycles ago) — so the matched per-element E8M0
    // scale is fetched here, at write-back, and applied combinationally.
    // mma_unit holds the per-slot scale regfile and answers this lookup;
    // mx_en=0 (no MX, or mx=0 MMA) makes the scale a passthrough.
    output logic [$clog2(M*N)-1:0] mx_idx,    // = wr_idx_q (matched index)
    input  wire                mx_en,
    input  wire  [7:0]         mx_ea,
    input  wire  [7:0]         mx_eb,

    // gmem write port (byte-enable style: nbytes ∈ {1, 4})
    output logic               gmem_wr_en,
    output logic [GMEM_AW-1:0] gmem_wr_addr,
    output logic [31:0]        gmem_wr_data,
    output logic [2:0]         gmem_wr_nbytes
);

    localparam int ELEMS = M * N;
    localparam int NW = $clog2(N);

    logic [3:0]         bar_q;
    logic [GMEM_AW-1:0] g_q;
    logic               dtype_q;
    logic [$clog2(ELEMS):0] idx_q;              // one extra bit for == ELEMS
    logic               req_active;             // request stage running
    logic               settled_q;              // current drain row has settled

    // request → write-back pipeline: stage [DRAIN_LAT-1] is the index
    // whose data is on drain_data this cycle
    logic [DRAIN_LAT-1:0]   v_pipe;
    logic [$clog2(ELEMS):0] idx_pipe [DRAIN_LAT];
    wire                    wr_v_q   = v_pipe[DRAIN_LAT-1];
    wire [$clog2(ELEMS):0]  wr_idx_q = idx_pipe[DRAIN_LAT-1];

    // Row-change settle bubble (ARRAY_SPEC §3): when the drain row index
    // changes (every N elements, and at burst start), the grid's
    // southbound chain needs a full extra cycle to settle before the
    // first capture of the new row — that bubble is what makes the
    // array's multicycle drain constraint RTL-enforced instead of
    // waived. drain_idx holds the row's first element for one dead
    // request cycle; the write-back stage ignores it. +M cycles per
    // burst (~3%).
    logic row_bubble;
    assign row_bubble = req_active && (idx_q[NW-1:0] == '0) && !settled_q;

    // MXFP8 scale applied to the drained fp32 BEFORE fp8 encode / fp32
    // write. wr_idx_q is the index matched to drain_data this cycle, so
    // mx_idx drives mma_unit's per-element scale lookup with the right
    // (row, col). Combinational — drain latency unchanged (mx_en=0 ⇒ noop).
    assign mx_idx = wr_idx_q[$clog2(ELEMS)-1:0];
    logic [31:0] scaled_data;
    mx_scale u_mx (.in32(drain_data), .ea(mx_ea), .eb(mx_eb),
                   .en(mx_en), .out32(scaled_data));

    logic [7:0] enc8;
    fp8_encode u_enc (.in32(scaled_data), .out8(enc8));

    assign drain_idx    = idx_q[$clog2(ELEMS)-1:0];
    assign gmem_wr_en   = wr_v_q;
    assign gmem_wr_addr = dtype_q ? (g_q + GMEM_AW'(wr_idx_q))
                                  : (g_q + (GMEM_AW'(wr_idx_q) << 2));
    assign gmem_wr_data = dtype_q ? {24'h0, enc8} : scaled_data;
    assign gmem_wr_nbytes = dtype_q ? 3'd1 : 3'd4;

    always_ff @(posedge clk) begin
        done <= 1'b0;
        if (rst) begin
            busy <= 1'b0;
            done_bar <= 4'd0;
            bar_q <= 4'd0; g_q <= '0; dtype_q <= 1'b0; idx_q <= '0;
            drain_slot <= '0;
            req_active <= 1'b0; settled_q <= 1'b0;
            v_pipe <= '0;
            for (int s = 0; s < DRAIN_LAT; s++) idx_pipe[s] <= '0;
        end else begin
            if (start) begin
`ifndef SYNTHESIS
                assert (!busy) else $fatal(1, "STORE start while busy");
`endif
                busy      <= 1'b1;
                bar_q     <= start_bar;
                g_q       <= start_gmem;
                dtype_q   <= start_dtype;
                drain_slot<= start_slot;
                idx_q     <= '0;
                req_active<= 1'b1;
                settled_q <= 1'b0;
                v_pipe    <= '0;
            end else if (busy) begin
                // write-back pipeline: the drain register chain answers
                // a request DRAIN_LAT cycles later (settle bubbles are
                // not requests)
                v_pipe <= DRAIN_LAT'({v_pipe, req_active && !row_bubble});
                idx_pipe[0] <= idx_q;
                for (int s = 1; s < DRAIN_LAT; s++)
                    idx_pipe[s] <= idx_pipe[s-1];
                if (wr_v_q && wr_idx_q == ($clog2(ELEMS)+1)'(ELEMS - 1)) begin
                    busy     <= 1'b0;
                    done     <= 1'b1;
                    done_bar <= bar_q;
                    v_pipe   <= '0;
                end
                // request stage
                if (req_active) begin
                    if (row_bubble) begin
                        settled_q <= 1'b1;   // hold idx one extra cycle
                    end else begin
                        idx_q <= idx_q + 1'b1;
                        if (idx_q[NW-1:0] == {NW{1'b1}})
                            settled_q <= 1'b0;   // next idx starts a new row
                        if (idx_q == ($clog2(ELEMS)+1)'(ELEMS - 1)) begin
                            req_active <= 1'b0;
                        end
                    end
                end
            end
        end
    end

endmodule

`default_nettype wire
