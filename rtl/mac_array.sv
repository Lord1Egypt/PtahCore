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
// drain_data (combinational mux over the grid, row-major).

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
    logic [31:0] kc;
    assign kc = k_q;
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
    logic        cell_en, cell_zero;
    assign cell_en   = busy;
    assign cell_zero = busy && accum_q == 1'b0 && (k_q == '0);

    logic [31:0] drain_grid [M*N];
    generate
        for (gi = 0; gi < M; gi++) begin : row
            for (gj = 0; gj < N; gj++) begin : col
                mac_cell #(.TMEM_SLOTS(TMEM_SLOTS), .SLOT_W(SLOT_W)) u_cell (
                    .clk(clk), .rst(rst),
                    .en(cell_en), .zero(cell_zero), .slot(slot_q),
                    .a_f32(a_f32[gi]), .b_f32(b_f32[gj]),
                    .drain_slot(drain_slot),
                    .drain_out(drain_grid[gi*N + gj])
                );
            end
        end
    endgenerate

    assign drain_data = drain_grid[drain_idx];

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
            if (k_q == 32'(K) - 32'd1) begin   // last column reached
                busy <= 1'b0;
                done <= 1'b1;
            end
        end
    end

endmodule

`default_nettype wire
