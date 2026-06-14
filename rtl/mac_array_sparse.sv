// mac_array_sparse — 2:4 structured-sparsity MAC array (Phase 9b).
// Twin: pymodel/mac_array.py (sparse path) / golden/sparse24.py.
//
// Proves the 2:4 sparse COMPUTE datapath in real RTL, K/2 steps (~2×),
// bit-exact vs the dense matmul of the decompressed A. It reuses the
// verified mac_cell leaf UNTOUCHED — the per-cell 2-of-4 B select lives in
// the array wiring (a mux per cell feeding mac_cell.b_f32), so none of the
// five hardened/abutted GDS modules (mac_cell/tile/grid/array) change and
// the dense path stays bit-identical.
//
// Why a per-cell select (see docs/SPARSITY.md): A is 2:4-compressed along
// K — a_vals[i] holds row i's 2 kept values per group, a_meta[i] the two
// 2-bit kept-lane indices. The broadcast array shares B down each column,
// but the kept lane is PER ROW, so each cell (i,j) must pick its own lane
// from the column's 4-lane group window using row i's metadata:
//     cell(i,j): acc += dec(a_vals[i,s]) · dec(B[j, 4·g + meta_sel[i]])
// with step s → group g = s/2, sub-step which = s%2, meta_sel = the
// which-th kept lane of group g for row i.
//
// This flat array is the reference realization; folding the select into the
// abutted traveling-clock array (widening the tile B feedthrough 1→4 lanes
// + routing meta_sel) is the chip re-harden step (docs/SPARSITY.md), which
// is why it lives here, standalone and verified, rather than inside the
// hardened mac_grid.

`default_nettype none

module mac_array_sparse #(
    parameter int M = 32,
    parameter int N = 32,
    parameter int K = 32,                 // must be a multiple of 4
    parameter int TMEM_SLOTS = 4,
    parameter int SLOT_W = 2
) (
    input  wire                     clk,
    input  wire                     rst,

    input  wire                     start,
    input  wire [M*(K/2)*8-1:0]     a_vals,   // (M, K/2) fp8 kept values
    input  wire [M*(K/4)*8-1:0]     a_meta,   // (M, K/4) metadata bytes
    input  wire [N*K*8-1:0]         b_tile,   // (N, K) fp8 row-major (dense)
    input  wire [SLOT_W-1:0]        start_slot,
    input  wire                     start_accum,
    input  wire                     start_fmt,

    output logic                    busy,
    output logic                    done,     // 1-cycle pulse

    input  wire [SLOT_W-1:0]        drain_slot,
    input  wire [$clog2(M*N)-1:0]   drain_idx,
    output logic [31:0]             drain_data
);

    localparam int HALFK = K / 2;             // kept values per row
    localparam int GROUPS = K / 4;            // 2:4 groups per row
    localparam int NSTEP = K / 2;             // sparse step count (~2×)
    localparam int SW = (NSTEP > 1) ? $clog2(NSTEP) : 1;
    localparam int GW = (GROUPS > 1) ? $clog2(GROUPS) : 1;

    // ── latched operands + control ───────────────────────────────────
    logic [M*HALFK*8-1:0] av_lat;
    logic [M*GROUPS*8-1:0] am_lat;
    logic [N*K*8-1:0]      b_lat;
    logic [SLOT_W-1:0]     slot_q;
    logic                  accum_q, fmt_q;
    logic [31:0]           k_q;

    // step s → group g = s/2, sub-step which = s%2 (clamped during flush)
    logic [SW-1:0] sc;
    assign sc = (k_q < 32'(NSTEP)) ? SW'(k_q) : SW'(NSTEP - 1);
    wire [GW-1:0] g_idx  = GW'(sc >> 1);
    wire          which  = sc[0];

    // ── A kept value per row (constant K/2 window, then the sc mux) ───
    wire [7:0] a_byte [M];
    wire [1:0] msel   [M];                    // per-row selected lane (0..3)
    generate
        for (genvar gi = 0; gi < M; gi++) begin : a_sel
            wire [HALFK*8-1:0] avwin = av_lat[gi*HALFK*8 +: HALFK*8];
            assign a_byte[gi] = avwin[sc*8 +: 8];
            // metadata byte for this row's current group, then pick the
            // which-th 2-bit kept-lane index (idx0=[1:0], idx1=[3:2]).
            wire [GROUPS*8-1:0] amwin = am_lat[gi*GROUPS*8 +: GROUPS*8];
            wire [7:0] mbyte = amwin[g_idx*8 +: 8];
            assign msel[gi] = which ? mbyte[3:2] : mbyte[1:0];
        end
    endgenerate

    // ── B group window per column: the 4 lanes B[j, 4g .. 4g+3] ──────
    // Constant K-byte window per column, then the (4·g) group offset.
    wire [31:0] b_lane [N][4];                // decoded fp32, 4 lanes/col
    logic [31:0] a_f32 [M];
    genvar gi, gj, gl;
    generate
        for (gi = 0; gi < M; gi++) begin : adec
            fp8_decode u (.in8(a_byte[gi]), .fmt(fmt_q), .out(a_f32[gi]));
        end
        for (gj = 0; gj < N; gj++) begin : bwin
            wire [K*8-1:0] bw = b_lat[gj*K*8 +: K*8];
            wire [GW+2-1:0] base = {g_idx, 2'b00};   // 4·g
            for (gl = 0; gl < 4; gl++) begin : lane
                wire [7:0] bb = bw[(base + gl)*8 +: 8];
                fp8_decode u (.in8(bb), .fmt(fmt_q), .out(b_lane[gj][gl]));
            end
        end
    endgenerate

    // ── control wave ─────────────────────────────────────────────────
    logic cell_en, cell_zero;
    assign cell_en   = busy && (k_q < 32'(NSTEP));
    assign cell_zero = busy && (accum_q == 1'b0) && (k_q == '0);

    // ── the cell grid: per-cell 2-of-4 B select → mac_cell.b_f32 ─────
    wire [31:0] cell_drain [M][N];
    generate
        for (gi = 0; gi < M; gi++) begin : grow
            for (gj = 0; gj < N; gj++) begin : gcol
                // row gi's metadata selects column gj's B lane (the mux
                // that, abutted, would live inside the tile — sparse_select)
                logic [31:0] b_used;
                always_comb case (msel[gi])
                    2'd0:    b_used = b_lane[gj][0];
                    2'd1:    b_used = b_lane[gj][1];
                    2'd2:    b_used = b_lane[gj][2];
                    default: b_used = b_lane[gj][3];
                endcase
`ifdef SYNTHESIS
                mac_cell u_cell (
`else
                mac_cell #(.TMEM_SLOTS(TMEM_SLOTS), .SLOT_W(SLOT_W)) u_cell (
`endif
                    .clk(clk), .rst(rst),
                    .en(cell_en), .zero(cell_zero), .slot(slot_q),
                    .a_f32(a_f32[gi]), .b_f32(b_used),
                    .drain_slot(drain_slot),
                    .drain_out(cell_drain[gi][gj])
                );
            end
        end
    endgenerate

    // ── drain: row-major mux over the cell accumulators ──────────────
    localparam int NWID = (N > 1) ? $clog2(N) : 1;
    localparam int MWID = (M > 1) ? $clog2(M) : 1;
    wire [NWID-1:0] dcol = drain_idx[NWID-1:0];
    wire [MWID-1:0] drow = drain_idx[$clog2(M*N)-1:NWID];
    assign drain_data = cell_drain[drow][dcol];

    // ── FSM: K/2 multiply cycles + 1 flush (cell's registered product) ─
    always_ff @(posedge clk) begin
        done <= 1'b0;
        if (rst) begin
            busy <= 1'b0; av_lat <= '0; am_lat <= '0; b_lat <= '0;
            slot_q <= '0; accum_q <= 1'b0; fmt_q <= 1'b0; k_q <= '0;
        end else if (start) begin
`ifndef SYNTHESIS
            assert (!busy) else $fatal(1, "sparse MMA start while busy");
`endif
            busy <= 1'b1; av_lat <= a_vals; am_lat <= a_meta; b_lat <= b_tile;
            slot_q <= start_slot; accum_q <= start_accum; fmt_q <= start_fmt;
            k_q <= '0;
        end else if (busy) begin
            k_q <= k_q + 1'b1;
            // last product registers on the edge leaving k_q==NSTEP-1 and
            // accumulates on the next (en_q delayed one), so finish at NSTEP.
            if (k_q == 32'(NSTEP)) begin
                busy <= 1'b0;
                done <= 1'b1;
            end
        end
    end

endmodule

`default_nettype wire
