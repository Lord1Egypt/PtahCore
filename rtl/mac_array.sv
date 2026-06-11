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
    logic [7:0] a_col [M];
    logic [7:0] b_col [N];
    // column index, clamped during the flush cycle (k_q == K) so the
    // operand part-select never runs past the latched tile
    logic [31:0] kc;
    assign kc = (k_q < 32'(K)) ? k_q : (32'(K) - 32'd1);
    always_comb begin
        for (int i = 0; i < M; i++)
            a_col[i] = a_lat[(32'(i)*32'(K) + kc)*8 +: 8];
        for (int j = 0; j < N; j++)
            b_col[j] = b_lat[(32'(j)*32'(K) + kc)*8 +: 8];
    end

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

    mac_grid #(.M(M), .N(N), .TMEM_SLOTS(TMEM_SLOTS), .SLOT_W(SLOT_W)) u_grid (
        .clk_v   ({M{clk}}),
        .rst_v   ({M{rst}}),
        .en_v    ({M{cell_en}}),
        .zero_v  ({M{cell_zero}}),
        .slot_v  ({M{slot_q}}),
        .dslot_v ({M{drain_slot}}),
        .row_hit_v(row_hit),
        .a_v     (a_bus),
        .b_n_flat(b_bus),
        .clk_s   (clk),
        .drain_col_sel(drain_idx[NW-1:0]),
        .drain_data(drain_data)
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
            // K multiply cycles (0..K-1) + 1 pipeline-flush cycle (K).
            // The final accumulate latches on the edge leaving k_q==K, so
            // done pulses then and drain is valid the following cycle.
            if (k_q == 32'(K)) begin
                busy <= 1'b0;
                done <= 1'b1;
            end
        end
    end

endmodule

`default_nettype wire
