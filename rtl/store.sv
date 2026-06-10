// store — ASYNC drain engine, TMEM slot → gmem. Twin: pymodel/store.py.
//
// One fp32 element per cycle from the array's drain port (combinational
// read contract: drain_data reflects drain_slot/drain_idx same cycle).
// dtype=0 writes 4-byte fp32; dtype=1 converts through fp8_encode
// (RNE, saturating e4m3) and writes 1 byte.
//
// PtahCore's flagship ISA improvement: completion is a barrier arrival
// (done pulse), never a front-end stall — epilogue overlap is free.

`default_nettype none

module store #(
    parameter int M = 32,
    parameter int N = 32,
    parameter int SLOT_W = 2,
    parameter int GMEM_AW = 32
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

    // drain port into the array (combinational data return)
    output logic [SLOT_W-1:0]  drain_slot,
    output logic [$clog2(M*N)-1:0] drain_idx,
    input  wire  [31:0]        drain_data,

    // gmem write port (byte-enable style: nbytes ∈ {1, 4})
    output logic               gmem_wr_en,
    output logic [GMEM_AW-1:0] gmem_wr_addr,
    output logic [31:0]        gmem_wr_data,
    output logic [2:0]         gmem_wr_nbytes
);

    localparam int ELEMS = M * N;

    logic [3:0]         bar_q;
    logic [GMEM_AW-1:0] g_q;
    logic               dtype_q;
    logic [$clog2(ELEMS):0] idx_q;              // one extra bit for == ELEMS

    logic [7:0] enc8;
    fp8_encode u_enc (.in32(drain_data), .out8(enc8));

    assign drain_idx    = idx_q[$clog2(ELEMS)-1:0];
    assign gmem_wr_en   = busy;
    assign gmem_wr_addr = dtype_q ? (g_q + GMEM_AW'(idx_q))
                                  : (g_q + (GMEM_AW'(idx_q) << 2));
    assign gmem_wr_data = dtype_q ? {24'h0, enc8} : drain_data;
    assign gmem_wr_nbytes = dtype_q ? 3'd1 : 3'd4;

    always_ff @(posedge clk) begin
        done <= 1'b0;
        if (rst) begin
            busy <= 1'b0;
            done_bar <= 4'd0;
            bar_q <= 4'd0; g_q <= '0; dtype_q <= 1'b0; idx_q <= '0;
            drain_slot <= '0;
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
            end else if (busy) begin
                idx_q <= idx_q + 1'b1;
                if (idx_q == ($clog2(ELEMS)+1)'(ELEMS - 1)) begin
                    busy     <= 1'b0;
                    done     <= 1'b1;
                    done_bar <= bar_q;
                end
            end
        end
    end

endmodule

`default_nettype wire
