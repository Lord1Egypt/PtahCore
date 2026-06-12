// mac_array — the M×N broadcast MAC grid. Twin: pymodel/mac_array.py.
//
// Operand tiles are latched at start (A is M×K, B is N×K, both fp8
// row-major). Each of the K cycles selects column k from the latched
// tiles, decodes it with M + N edge decoders (NOT M·N — the whole point
// of the broadcast layout), and drives every cell:
//     cell(i,j): acc[slot] += fp32(A[i,k]) * fp32(B[j,k])
// `zero` is asserted only on the first column when accum==0.
//
// The 1024 accumulators live inside the mac_cell leaves (distributed
// TMEM). STORE drains them one element per cycle through drain_idx →
// drain_data (row-major; the grid's southbound drain chain + registered
// south strip — see mac_grid.sv / docs/ARRAY_SPEC.md).
//
// LAUNCH BANKS (Phase 7d, CHIP_SPEC §2): every grid input goes through
// a TWO-STAGE register pipeline whose clocks are spine taps — the
// pre-delay contracts become launch-clock phases. Stage A (all
// interface data) is on the clk_s tap (≈ mid-period): capturing root-
// phase data there is hold-safe by phase alone. Stage B is per row
// (clk_lw_v[i]) / per column (clk_lb_v[j]) on deliberately LATE taps
// (row/col phase + the hold-contract lag): capturing stage A's
// mid-phase data there is again hold-safe by phase — even where the
// late tap wraps past one period — with NO min-delay assumptions (the
// 7c-3 lesson: logic min-delay floors are fiction; clock phase is
// physics). In simulation every tap is the chip clock (ptah_clkbuf is
// a wire): the banks are two uniform pipeline stages — compute +2
// cycles (done at k_q == K+2), drain request→data = 4 cycles (store's
// DRAIN_LAT: stage A, stage B, the grid's south register, capture).

`default_nettype none

module mac_array #(
    parameter int M = 32,
    parameter int N = 32,
    parameter int K = 32,
    parameter int TMEM_SLOTS = 4,
    parameter int SLOT_W = 2
) (
    input  wire                     clk,
    input  wire                     rst,

    // spine taps (sim: all = clk; chip: clk_spine outputs, CHIP_SPEC §1)
    input  wire [M-1:0]             clk_row_v,  // grid clk_v[i] = tap i
    input  wire [M-1:0]             clk_lw_v,   // stage-B west launch, row i
    input  wire [N-1:0]             clk_lb_v,   // stage-B B launch, column j
    input  wire                     clk_s,      // mid-period tap: stage A,
                                                // grid south strip, capture

    input  wire                     start,
    input  wire [M*K*8-1:0]         a_tile,   // (M,K) fp8 row-major
    input  wire [N*K*8-1:0]         b_tile,   // (N,K) fp8 row-major
    input  wire [SLOT_W-1:0]        start_slot,
    input  wire                     start_accum,
    input  wire                     start_fmt,

    output logic                    busy,
    output logic                    done,     // 1-cycle pulse at K-th step

    input  wire [SLOT_W-1:0]        drain_slot,
    input  wire [$clog2(M*N)-1:0]   drain_idx,
    output logic [31:0]             drain_data
);

    // ── latched operands + control ───────────────────────────────────
    logic [M*K*8-1:0] a_lat;
    logic [N*K*8-1:0] b_lat;
    logic [SLOT_W-1:0] slot_q;
    logic              accum_q, fmt_q;
    logic [31:0] k_q;                 // plain int counter — compare to K-1 directly

    // ── select column k ──────────────────────────────────────────────
    // a_lat byte for (i,k) is at element (i*K + k); likewise B (j*K + k).
    // Two-step select: a CONSTANT K·8-bit window per element, then the
    // kc mux inside it. Indexing the full M·K·8 latch with the runtime
    // kc makes yosys emit a full-width barrel shifter PER ELEMENT
    // (64 × $shiftx_8192 — the 7d-3 chip-synth OOM).
    wire [7:0] a_col [M];
    wire [7:0] b_col [N];
    // column index, clamped during the flush cycles (k_q >= K) so the
    // operand select never runs past the latched tile
    localparam int KW = (K > 1) ? $clog2(K) : 1;
    logic [KW-1:0] kc;
    assign kc = (k_q < 32'(K)) ? KW'(k_q) : KW'(K - 1);
    generate
        for (genvar gk = 0; gk < M; gk++) begin : col_a
            wire [K*8-1:0] win = a_lat[gk*K*8 +: K*8];
            assign a_col[gk] = win[kc*8 +: 8];
        end
        for (genvar gk = 0; gk < N; gk++) begin : col_b
            wire [K*8-1:0] win = b_lat[gk*K*8 +: K*8];
            assign b_col[gk] = win[kc*8 +: 8];
        end
    endgenerate

    // ── edge decoders: M for A column, N for B column ────────────────
    logic [31:0] a_f32 [M];
    logic [31:0] b_f32 [N];
    genvar gi, gj;
    generate
        for (gi = 0; gi < M; gi++)
            fp8_decode u_da (.in8(a_col[gi]), .fmt(fmt_q), .out(a_f32[gi]));
        for (gj = 0; gj < N; gj++)
            fp8_decode u_db (.in8(b_col[gj]), .fmt(fmt_q), .out(b_f32[gj]));
    endgenerate

    // ── the grid ─────────────────────────────────────────────────────
    // Cells are 2-stage pipelined: drive multiplies for k_q = 0..K-1, then
    // one flush cycle (k_q == K) where en is low but the cells' delayed
    // en_q completes the final accumulate. zero is asserted on k_q==0 and
    // the cell delays it to land with the first product.
    logic        cell_en, cell_zero;
    assign cell_en   = busy && (k_q < 32'(K));
    assign cell_zero = busy && accum_q == 1'b0 && (k_q == '0);

    // B operands flattened once for every row's north edge.
    logic [N*32-1:0] b_bus;
    always_comb begin
        for (int j = 0; j < N; j++)
            b_bus[j*32 +: 32] = b_f32[j];
    end

    // drain_idx is row-major (i*N + j); N is a power of two, so the low
    // $clog2(N) bits select the column inside a row and the high bits
    // decode to the grid's per-row row_hit (the tiles' southbound drain
    // chain delivers the selected row to the south strip). The grid
    // REGISTERS the drain at its south boundary (traveling-clock return
    // path — see mac_grid), so drain_data answers the drain_idx of the
    // PREVIOUS cycle, exactly as the per-row register did before 7c.
    localparam int NW = $clog2(N);
    logic [M-1:0] row_hit;
    always_comb begin
        for (int i = 0; i < M; i++)
            row_hit[i] = (drain_idx[$clog2(M*N)-1:NW] == ($clog2(M*N)-NW)'(i));
    end

    // Per-row west buses: in sim every row gets the same clock and the
    // same control in the same cycle (the chip-level spine stagger is a
    // physical-delay contract, not a behavioral one — ARRAY_SPEC §2).
    logic [M*32-1:0] a_bus;
    always_comb begin
        for (int i = 0; i < M; i++)
            a_bus[i*32 +: 32] = a_f32[i];
    end

    // ── launch banks (CHIP_SPEC §2): stage A on the clk_s tap ────────
    // rst_v stays direct ({M{rst}}): false-pathed, held many cycles,
    // no wave contract.
    logic [M-1:0]          sa_en_v, sa_zero_v, sa_hit;
    logic [M*SLOT_W-1:0]   sa_slot, sa_dslot;
    logic [M*32-1:0]       sa_a;
    logic [N*32-1:0]       sa_b;
    logic [NW-1:0]         sa_col_sel;
    always_ff @(posedge clk_s) begin
        sa_en_v    <= {M{cell_en}};
        sa_zero_v  <= {M{cell_zero}};
        sa_hit     <= row_hit;
        sa_slot    <= {M{slot_q}};
        sa_dslot   <= {M{drain_slot}};
        sa_a       <= a_bus;
        sa_b       <= b_bus;
        sa_col_sel <= drain_idx[NW-1:0];
    end

    // ── stage B: per-row west taps / per-column north taps ───────────
    // Per-scope registers + continuous assigns onto the bus slices:
    // clocked part-select writes from different clocks trip Verilator's
    // MULTIDRIVEN on the whole packed vector (the launch-bank variant
    // of the 7c-1 packed-array trap).
    wire [M-1:0]          l_en, l_zero, l_hit;
    wire [M*SLOT_W-1:0]   l_slot, l_dslot;
    wire [M*32-1:0]       l_a;
    generate
        for (genvar li = 0; li < M; li++) begin : launch_w
            logic              en_q, zero_q, hit_q;
            logic [SLOT_W-1:0] slot_lq, dslot_lq;
            logic [31:0]       a_q;
            always_ff @(posedge clk_lw_v[li]) begin
                en_q     <= sa_en_v[li];
                zero_q   <= sa_zero_v[li];
                hit_q    <= sa_hit[li];
                slot_lq  <= sa_slot[li*SLOT_W +: SLOT_W];
                dslot_lq <= sa_dslot[li*SLOT_W +: SLOT_W];
                a_q      <= sa_a[li*32 +: 32];
            end
            assign l_en[li]                     = en_q;
            assign l_zero[li]                   = zero_q;
            assign l_hit[li]                    = hit_q;
            assign l_slot[li*SLOT_W +: SLOT_W]  = slot_lq;
            assign l_dslot[li*SLOT_W +: SLOT_W] = dslot_lq;
            assign l_a[li*32 +: 32]             = a_q;
        end
    endgenerate

    wire [N*32-1:0] l_b;
    generate
        for (genvar lj = 0; lj < N; lj++) begin : launch_b
            logic [31:0] b_q;
            always_ff @(posedge clk_lb_v[lj])
                b_q <= sa_b[lj*32 +: 32];
            assign l_b[lj*32 +: 32] = b_q;
        end
    endgenerate

    // Drain column select walks with the same 2-stage depth as
    // row_hit (coherent settled-bus walk), staying on the clk_s tap;
    // drain_data is captured on it too: request → A → B → grid south
    // register → capture = 4 cycles (store's DRAIN_LAT).
    logic [NW-1:0] l_col_sel;
    logic [31:0]   drain_q;
    wire  [31:0]   grid_drain;
    always_ff @(posedge clk_s) begin
        l_col_sel <= sa_col_sel;
        drain_q   <= grid_drain;
    end
    assign drain_data = drain_q;

    // At chip P&R the grid is the hardened macro resolved from its
    // liberty model, which has no parameters — and the chip IS the
    // default 32×32 shape. Sim and unit hardening keep the overrides.
`ifdef GRID_MACRO
    mac_grid u_grid (
`else
    mac_grid #(.M(M), .N(N), .TMEM_SLOTS(TMEM_SLOTS), .SLOT_W(SLOT_W)) u_grid (
`endif
        .clk_v   (clk_row_v),
        .rst_v   ({M{rst}}),
        .en_v    (l_en),
        .zero_v  (l_zero),
        .slot_v  (l_slot),
        .dslot_v (l_dslot),
        .row_hit_v(l_hit),
        .a_v     (l_a),
        .b_n_flat(l_b),
        .drain_n_flat({N{32'h0}}),
        .clk_s   (clk_s),
        .drain_col_sel(l_col_sel),
        .drain_data(grid_drain)
    );

    // ── FSM ──────────────────────────────────────────────────────────
    always_ff @(posedge clk) begin
        done <= 1'b0;
        if (rst) begin
            busy <= 1'b0;
            a_lat <= '0; b_lat <= '0; slot_q <= '0;
            accum_q <= 1'b0; fmt_q <= 1'b0; k_q <= '0;
        end else if (start) begin
`ifndef SYNTHESIS
            assert (!busy) else $fatal(1, "MMA start while array busy");
`endif
            busy    <= 1'b1;
            a_lat   <= a_tile;
            b_lat   <= b_tile;
            slot_q  <= start_slot;
            accum_q <= start_accum;
            fmt_q   <= start_fmt;
            k_q     <= '0;
        end else if (busy) begin
            k_q <= k_q + 1'b1;
            // K multiply cycles (0..K-1) + the two launch stages + one
            // pipeline-flush cycle: the en wave reaches the cells two
            // cycles after k_q drives it, so the final accumulate
            // latches on the edge leaving k_q == K+2. (Physically the
            // far rows' flush extends a sub-period tail past that edge;
            // the next MMA issue is ≥2 cycles away by cmdproc
            // construction — CHIP_SPEC §2.)
            if (k_q == 32'(K) + 32'd2) begin
                busy <= 1'b0;
                done <= 1'b1;
            end
        end
    end

endmodule

`default_nettype wire
