// mma_unit — operand-fetch FSM + mac_array.
//
// The cmdproc's MMA issue gives only the SMEM offsets of the A and B
// tiles, not the tiles themselves. mac_array, however, latches full
// tiles at start. This wrapper bridges the two: on `start` it streams
// both tiles out of SMEM (RD_BYTES per cycle, A and B in parallel on
// the two read ports), assembles them into the wide operand registers,
// then pulses the array and reports `done` when the array finishes.
//
// FSM: IDLE → FETCH (NCHUNK reads, 1-cycle registered SMEM latency) →
//       RUN (array does K MAC steps) → done pulse → IDLE.
//
// rd_stall (from smem_phys): the SMEM did not service this cycle's
// read addresses (a 1RW bank collision with a LOAD line write) — hold
// the fetch pointer and discard the garbage arriving next cycle. With
// rd_stall tied low the fetch is cycle-identical to the original FSM.
//
// SMEM tile layout matches the array / golden model: A is (M,K) and B
// is (N,K), both fp8 row-major, so sequential RD_BYTES chunks fill the
// operand registers in order.

`default_nettype none

module mma_unit #(
    parameter int M = 32,
    parameter int N = 32,
    parameter int K = 32,
    parameter int TMEM_SLOTS = 4,
    parameter int SLOT_W   = 2,
    parameter int SMEM_AW  = 16,
    parameter int RD_BYTES = 32
) (
    input  wire                   clk,
    input  wire                   rst,

    // spine taps, passed through to the array (CHIP_SPEC §1/§2)
    input  wire [M-1:0]           clk_row_v,
    input  wire [M-1:0]           clk_lw_v,
    input  wire [N-1:0]           clk_lb_v,
    input  wire                   clk_s,

    // MMA issue (from cmdproc)
    input  wire                   start,
    input  wire [SMEM_AW-1:0]     a_smem,
    input  wire [SMEM_AW-1:0]     b_smem,
    input  wire [SLOT_W-1:0]      slot,
    input  wire                   accum,
    input  wire                   fmt,
    // MXFP8 (Phase 8): mx=1 fetches M E8M0 row scales from sa_smem and N
    // E8M0 col scales from sb_smem (each ≤ RD_BYTES, one extra read) and
    // holds them per slot until that slot is drained. mx=0 ⇒ cycle-identical
    // to the pre-Phase-8 fetch (no scale read, no extra cycle).
    input  wire                   mx,
    input  wire [SMEM_AW-1:0]     sa_smem,
    input  wire [SMEM_AW-1:0]     sb_smem,
    output logic                  busy,
    output logic                  done,        // 1-cycle pulse

    // SMEM read ports (registered: data valid next cycle)
    output logic [SMEM_AW-1:0]    rd_a_addr,
    input  wire  [RD_BYTES*8-1:0] rd_a_data,
    output logic [SMEM_AW-1:0]    rd_b_addr,
    input  wire  [RD_BYTES*8-1:0] rd_b_data,
    input  wire                   rd_stall,

    // drain port (passthrough to the array)
    input  wire [SLOT_W-1:0]      drain_slot,
    input  wire [$clog2(M*N)-1:0] drain_idx,
    output logic [31:0]           drain_data,

    // MXFP8 scale lookup answered for STORE. store drives mx_lk_idx with the
    // index matched to drain_data (its wr_idx_q); we return the per-element
    // E8M0 scales for the slot being drained. Combinational regfile read.
    input  wire [$clog2(M*N)-1:0] mx_lk_idx,
    output logic                  mx_lk_en,
    output logic [7:0]            mx_lk_ea,
    output logic [7:0]            mx_lk_eb
);

    localparam int A_BYTES = M * K;
    localparam int B_BYTES = N * K;
    localparam int NCHUNK  = (A_BYTES + RD_BYTES - 1) / RD_BYTES;  // A and B same K

    // ── operand registers + latched control ──────────────────────────
    // Assembled from per-chunk enable registers (generate block below) —
    // a dynamic part-select WRITE into the full M·K·8 vector makes yosys
    // emit full-width RMW shifter masks ($shift_8192, the other half of
    // the 7d-3 chip-synth OOM).
    wire [A_BYTES*8-1:0] a_reg;
    wire [B_BYTES*8-1:0] b_reg;
    logic [SMEM_AW-1:0]   a_base, b_base, sa_base, sb_base;
    logic [SLOT_W-1:0]    slot_q;
    logic                 accum_q, fmt_q, mx_q;

    // ── per-slot MXFP8 scale regfile (Phase 8) ───────────────────────
    // The scale belongs to the MMA that wrote the slot and must survive
    // until STORE drains it (async). Held here, looked up combinationally
    // at write-back by store (mx_lk_*). mxen_q[slot]=0 ⇒ plain drain.
    logic              mxen_q [TMEM_SLOTS];
    logic [7:0]        sa_q   [TMEM_SLOTS][M];   // M E8M0 row scales / slot
    logic [7:0]        sb_q   [TMEM_SLOTS][N];   // N E8M0 col scales / slot

    // ── FSM ──────────────────────────────────────────────────────────
    // SFETCH: the mx-only extra read that loads the M+N E8M0 scale bytes.
    typedef enum logic [1:0] { IDLE, FETCH, SFETCH, RUN } state_t;
    state_t st;
    logic   spend;   // SFETCH: scale address issued, data valid next cycle
    // Pipelined fetch: `f` is the next chunk to ADDRESS; (pend_v,
    // pend_idx) tracks the single in-flight read whose data arrives
    // this cycle (registered SMEM). An issue only advances f when the
    // SMEM serviced it (!rd_stall); a stalled issue leaves no in-flight
    // read, so the garbage data the colliding write produced is never
    // captured.
    logic [31:0] f;
    logic        pend_v;
    logic [31:0] pend_idx;

    // Per-chunk capture: decoded enables, per-scope regs + assigns
    // (the launch-bank pattern — no packed-vector multidrive, no RMW
    // barrel shifters at synth).
    generate
        for (genvar gc = 0; gc < NCHUNK; gc++) begin : chunk
            logic [RD_BYTES*8-1:0] a_q, b_q;
            always_ff @(posedge clk) begin
                if (rst) begin
                    a_q <= '0;
                    b_q <= '0;
                end else if (st == FETCH && pend_v && pend_idx == 32'(gc)) begin
                    a_q <= rd_a_data;
                    b_q <= rd_b_data;
                end
            end
            assign a_reg[gc*RD_BYTES*8 +: RD_BYTES*8] = a_q;
            assign b_reg[gc*RD_BYTES*8 +: RD_BYTES*8] = b_q;
        end
    endgenerate

    // array instance
    logic        arr_start, arr_busy, arr_done;
    mac_array #(.M(M), .N(N), .K(K), .TMEM_SLOTS(TMEM_SLOTS), .SLOT_W(SLOT_W)) u_arr (
        .clk(clk), .rst(rst),
        .clk_row_v(clk_row_v), .clk_lw_v(clk_lw_v),
        .clk_lb_v(clk_lb_v), .clk_s(clk_s),
        .start(arr_start), .a_tile(a_reg), .b_tile(b_reg),
        .start_slot(slot_q), .start_accum(accum_q), .start_fmt(fmt_q),
        .busy(arr_busy), .done(arr_done),
        .drain_slot(drain_slot), .drain_idx(drain_idx), .drain_data(drain_data)
    );

    assign busy = (st != IDLE);

    // SMEM read addresses (combinational: address chunk `f`, or the scale
    // bases during the SFETCH micro-phase)
    assign rd_a_addr = (st == SFETCH) ? sa_base : (a_base + SMEM_AW'(f * RD_BYTES));
    assign rd_b_addr = (st == SFETCH) ? sb_base : (b_base + SMEM_AW'(f * RD_BYTES));

    // ── per-slot scale capture (SFETCH data cycle) ───────────────────
    // Static per-byte slices (constant k) → no barrel shifters at synth.
    always_ff @(posedge clk) begin
        if (st == SFETCH && spend) begin
            for (int k = 0; k < M; k++) sa_q[slot_q][k] <= rd_a_data[k*8 +: 8];
            for (int k = 0; k < N; k++) sb_q[slot_q][k] <= rd_b_data[k*8 +: 8];
        end
    end

    // ── scale lookup for store (combinational regfile read) ──────────
    localparam int NW   = $clog2(N);
    localparam int IDXW = $clog2(M*N);
    wire [$clog2(M)-1:0] lk_i = mx_lk_idx[IDXW-1:NW];   // row  i = idx / N
    wire [NW-1:0]        lk_j = mx_lk_idx[NW-1:0];       // col  j = idx % N
    assign mx_lk_en = mxen_q[drain_slot];
    assign mx_lk_ea = sa_q[drain_slot][lk_i];
    assign mx_lk_eb = sb_q[drain_slot][lk_j];

    always_ff @(posedge clk) begin
        done      <= 1'b0;
        arr_start <= 1'b0;
        if (rst) begin
            st <= IDLE; f <= 0; pend_v <= 1'b0; pend_idx <= 0;
            a_base <= '0; b_base <= '0; slot_q <= '0; accum_q <= 0; fmt_q <= 0;
            sa_base <= '0; sb_base <= '0; mx_q <= 1'b0; spend <= 1'b0;
            for (int s = 0; s < TMEM_SLOTS; s++) mxen_q[s] <= 1'b0;
        end else begin
            case (st)
                IDLE: if (start) begin
                    a_base <= a_smem; b_base <= b_smem;
                    sa_base <= sa_smem; sb_base <= sb_smem;
                    slot_q <= slot; accum_q <= accum; fmt_q <= fmt;
                    mx_q   <= mx;          // this MMA's mx (FETCH→SFETCH gate)
                    mxen_q[slot] <= mx;    // per-slot drain flag (set OR clear)
                    f      <= 0;            // fetch-cycle 0 addresses chunk 0 next cy
                    pend_v <= 1'b0;
                    st     <= FETCH;
                end
                FETCH: begin
                    // the in-flight chunk addressed last cycle lands in
                    // its per-chunk register (chunk generate, above)
                    if (pend_v && pend_idx == 32'(NCHUNK) - 32'd1) begin
                        pend_v <= 1'b0;
                        if (mx_q) begin
                            st    <= SFETCH;   // mx: one extra read for scales
                            spend <= 1'b0;
                        end else begin
                            arr_start <= 1'b1; // all chunks captured
                            st        <= RUN;
                        end
                    end else if (!rd_stall && f < 32'(NCHUNK)) begin
                        pend_v   <= 1'b1;      // this cycle's address is serviced
                        pend_idx <= f;
                        f        <= f + 32'd1;
                    end else begin
                        pend_v <= 1'b0;        // stalled: next cycle's data is garbage
                    end
                end
                SFETCH: begin
                    // address scales (rd_*_addr → sa/sb_base) then capture
                    // the data the next cycle; rd_stall retries the address.
                    if (spend) begin
                        spend     <= 1'b0;     // captured (scale-capture block)
                        arr_start <= 1'b1;
                        st        <= RUN;
                    end else if (!rd_stall) begin
                        spend <= 1'b1;         // serviced: data valid next cycle
                    end
                end
                RUN: if (arr_done) begin
                    done <= 1'b1;
                    st   <= IDLE;
                end
                default: st <= IDLE;
            endcase
        end
    end

endmodule

`default_nettype wire
