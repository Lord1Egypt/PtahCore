// mac_grid — the M×N abutted tile sea + south drain strip (Phase 7c).
//
// docs/ARRAY_SPEC.md is the contract. The grid is the physical array:
// M rows of N mac_tiles abutting in BOTH axes. Every west-edge signal
// is a per-row port (clk_v[i], rst_v[i], en_v[i], zero_v[i], slot_v,
// dslot_v, row_hit_v[i], a_v[i]) because at chip scale each row is
// served in its own clock phase: row i's clock arrives i·δs after row
// 0's (the southward stagger that matches the B/drain feedthrough
// waves — ARRAY_SPEC §1). The spine that realizes the stagger lives in
// chip_top; here the per-row ports simply expose the contract.
//
// Vertical chains (north→south, through the tiles' own feedthroughs):
//   B:     b_n_flat enters row 0's north pins; tile (i,j).b_out feeds
//          tile (i+1,j).b_in — the column broadcast.
//   drain: row_hit selects ONE row; its tiles drive their accumulators
//          onto the southbound chain, every other tile passes its north
//          neighbour through. Row 0's drain_n_in ties to 0.
//
// South strip: the only stdcells in the hardened grid — the column mux
// walking a SETTLED bus (row_hit and the drained slot change at most
// once per 32 reads; STORE's row-change bubble guarantees the chain has
// settled before the first capture of a row — ARRAY_SPEC §3) and the
// single drain register, clocked at the end-of-spine phase (clk_s).
// drain_data answers the PREVIOUS cycle's {row_hit_v, drain_col_sel}.
//
// In simulation all clk_v bits carry the same clock and the
// feedthroughs are zero-delay, so the grid is bit-identical to the
// flat M×N mac_cell grid verified since Phase 3.

`default_nettype none

module mac_grid #(
    parameter int M          = 32,
    parameter int N          = 32,
    parameter int TMEM_SLOTS = 4,
    parameter int SLOT_W     = 2
) (
    // ── west, per row (chip_top delivers in row-i phase) ─────────────
    input  wire [M-1:0]            clk_v,
    input  wire [M-1:0]            rst_v,
    input  wire [M-1:0]            en_v,
    input  wire [M-1:0]            zero_v,
    input  wire [M*SLOT_W-1:0]     slot_v,
    input  wire [M*SLOT_W-1:0]     dslot_v,
    input  wire [M-1:0]            row_hit_v,
    input  wire [M*32-1:0]         a_v,

    // ── north (row 0's b_in pins; traveling j·δe arrival) ────────────
    input  wire [N*32-1:0]         b_n_flat,

    // ── south strip ──────────────────────────────────────────────────
    input  wire                    clk_s,
    input  wire [$clog2(N)-1:0]    drain_col_sel,
    output logic [31:0]            drain_data
);

    // West→east traveling nets, one chain per row (element j drives
    // tile (i,j)'s west edge; its east edge drives element j+1).
    // PACKED arrays on purpose: the chains are element-wise acyclic,
    // but Verilator orders whole unpacked arrays as one signal and
    // reports false UNOPTFLAT circularity (and 5.020's split_var can't
    // split multi-dim unpacked). Packed arrays order bit-wise.
    wire [M-1:0][N:0]             t_clk;
    wire [M-1:0][N:0]             t_rst;
    wire [M-1:0][N:0]             t_en;
    wire [M-1:0][N:0]             t_zero;
    wire [M-1:0][N:0][SLOT_W-1:0] t_slot;
    wire [M-1:0][N:0][SLOT_W-1:0] t_dslot;
    wire [M-1:0][N:0]             t_hit;
    wire [M-1:0][N:0][31:0]       t_a;

    // North→south chains, one per column (element i drives tile
    // (i,j)'s north edge; its south edge drives element i+1).
    wire [M:0][N-1:0][31:0] v_b;
    wire [M:0][N-1:0][31:0] v_dr;

    genvar gi, gj;
    generate
        for (gi = 0; gi < M; gi++) begin : row
            assign t_clk[gi][0]   = clk_v[gi];
            assign t_rst[gi][0]   = rst_v[gi];
            assign t_en[gi][0]    = en_v[gi];
            assign t_zero[gi][0]  = zero_v[gi];
            assign t_slot[gi][0]  = slot_v[gi*SLOT_W +: SLOT_W];
            assign t_dslot[gi][0] = dslot_v[gi*SLOT_W +: SLOT_W];
            assign t_hit[gi][0]   = row_hit_v[gi];
            assign t_a[gi][0]     = a_v[gi*32 +: 32];

            for (gj = 0; gj < N; gj++) begin : col
                // Hard macro in the hierarchical flow (parameterless
                // .lib blackbox, TMEM_SLOTS=4 / SLOT_W=2 baked in).
`ifdef SYNTHESIS
                mac_tile u_tile (
`else
                mac_tile #(.TMEM_SLOTS(TMEM_SLOTS), .SLOT_W(SLOT_W)) u_tile (
`endif
                    .clk_in(t_clk[gi][gj]),   .clk_out(t_clk[gi][gj+1]),
                    .rst_in(t_rst[gi][gj]),   .rst_out(t_rst[gi][gj+1]),
                    .en_in(t_en[gi][gj]),     .en_out(t_en[gi][gj+1]),
                    .zero_in(t_zero[gi][gj]), .zero_out(t_zero[gi][gj+1]),
                    .slot_in(t_slot[gi][gj]), .slot_out(t_slot[gi][gj+1]),
                    .drain_slot_in(t_dslot[gi][gj]),
                    .drain_slot_out(t_dslot[gi][gj+1]),
                    .row_hit_in(t_hit[gi][gj]), .row_hit_out(t_hit[gi][gj+1]),
                    .a_in(t_a[gi][gj]),       .a_out(t_a[gi][gj+1]),
                    .b_in(v_b[gi][gj]),       .b_out(v_b[gi+1][gj]),
                    .drain_n_in(v_dr[gi][gj]),
                    .drain_s_out(v_dr[gi+1][gj])
                );
            end
        end

        for (gj = 0; gj < N; gj++) begin : north
            assign v_b[0][gj]  = b_n_flat[gj*32 +: 32];
            assign v_dr[0][gj] = 32'h0;
        end
    endgenerate

    // ── south strip: column mux over the settled chain + the drain
    //    register (the row-internal register of 7b-3, moved to the grid
    //    boundary — external latency unchanged) ──────────────────────
    always_ff @(posedge clk_s) begin
        drain_data <= v_dr[M][drain_col_sel];
    end

endmodule

`default_nettype wire
