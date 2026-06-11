// mac_tile — the abutment tile: a mac_cell plus the TILE_SPEC boundary.
//
// docs/TILE_SPEC.md builds the array out of identical tiles that abut
// edge-to-edge with NO parent routing over them, and a source-synchronous
// "traveling" clock instead of a chip-wide tree. Every signal therefore
// enters on the edge that carries it and is fed through to the opposite
// edge for the next tile:
//
//        west in            east out          north in      south out
//   clk_in, rst_in      clk_out, rst_out     b_in[32]       b_out[32]
//   en/zero/slot        en/zero/slot         drain_n_in     drain_s_out
//   drain_slot_in       drain_slot_out
//   row_hit_in          row_hit_out
//   a_in[32]            a_out[32]
//
// In simulation the feedthroughs are plain wires (zero delay), so the
// tile is bit-identical to a bare mac_cell. Physically each feedthrough
// is a buffer chain inside the tile; the clock and the west→east data
// travel TOGETHER, so a cell only ever sees the bounded local skew
// between its own clock tap and its own data tap — never the global
// insertion of a 1.5 mm tree (the Phase-7a row measured that wave at
// ~1.7 ns; the traveling clock is what makes it free).
//
// Drain (vertical, for row stacking): one cell per column is selected
// per cycle by row_hit (decoded at the array's west edge and traveling
// east with the control). A selected tile drives its accumulator onto
// the southbound chain; an unselected tile passes its north neighbour
// through. The column mux over drain_s_out lives OUTSIDE the tiles
// (south of the array, with STORE). The standalone 1×32 row ties
// row_hit_in = 1 and drain_n_in = 0.
//
// The verified mac_cell compute core is instantiated untouched.

`default_nettype none

module mac_tile #(
    parameter int TMEM_SLOTS = 4,
    parameter int SLOT_W     = 2
) (
    // ── west in ──────────────────────────────────────────────────────
    input  wire               clk_in,
    input  wire               rst_in,
    input  wire               en_in,
    input  wire               zero_in,
    input  wire [SLOT_W-1:0]  slot_in,
    input  wire [SLOT_W-1:0]  drain_slot_in,
    input  wire               row_hit_in,
    input  wire [31:0]        a_in,

    // ── east out (feedthrough to the next tile) ──────────────────────
    output wire               clk_out,
    output wire               rst_out,
    output wire               en_out,
    output wire               zero_out,
    output wire [SLOT_W-1:0]  slot_out,
    output wire [SLOT_W-1:0]  drain_slot_out,
    output wire               row_hit_out,
    output wire [31:0]        a_out,

    // ── north in ─────────────────────────────────────────────────────
    input  wire [31:0]        b_in,
    input  wire [31:0]        drain_n_in,

    // ── south out ────────────────────────────────────────────────────
    output wire [31:0]        b_out,
    output logic [31:0]       drain_s_out
);

    // West→east feedthroughs. Zero-delay wires in sim; buffer chains in
    // the hardened tile (clk_in→clk_out insertion is characterised and
    // matched to the data feedthrough delay — TILE_SPEC §3).
    assign clk_out        = clk_in;
    assign rst_out        = rst_in;
    assign en_out         = en_in;
    assign zero_out       = zero_in;
    assign slot_out       = slot_in;
    assign drain_slot_out = drain_slot_in;
    assign row_hit_out    = row_hit_in;
    assign a_out          = a_in;

    // North→south feedthrough (column broadcast for stacked rows).
    assign b_out = b_in;

    // ── compute core (verified, untouched) ───────────────────────────
    logic [31:0] cell_drain;
`ifdef SYNTHESIS
    mac_cell u_cell (
`else
    mac_cell #(.TMEM_SLOTS(TMEM_SLOTS), .SLOT_W(SLOT_W)) u_cell (
`endif
        .clk(clk_in), .rst(rst_in),
        .en(en_in), .zero(zero_in), .slot(slot_in),
        .a_f32(a_in), .b_f32(b_in),
        .drain_slot(drain_slot_in),
        .drain_out(cell_drain)
    );

    // ── southbound drain chain ───────────────────────────────────────
    assign drain_s_out = row_hit_in ? cell_drain : drain_n_in;

endmodule

`default_nettype wire
