// mac_row — one 1×N row of mac_cells: the physical tiling unit.
//
// docs/TILE_SPEC.md builds the 32×32 array out of hardened rows, so the
// row exists as its own module: N cells sharing the row's A operand
// (west-edge broadcast), each taking its own column B operand (north
// edge), draining one element per cycle through drain_idx → drain_out
// (south edge, combinational mux). Control (en/zero/slot) is broadcast.
//
// Pure structure — every cell behaves exactly as it did when mac_array
// instantiated it directly; mac_array now stamps M of these rows.

`default_nettype none

module mac_row #(
    parameter int N          = 32,
    parameter int TMEM_SLOTS = 4,
    parameter int SLOT_W     = 2
) (
    input  wire                   clk,
    input  wire                   rst,

    input  wire                   en,        // do one MAC this cycle
    input  wire                   zero,      // zero accumulator before MAC
    input  wire [SLOT_W-1:0]      slot,
    input  wire [31:0]            a_f32,        // row broadcast (west)
    input  wire [N*32-1:0]        b_f32_flat,   // per-column operand (north)

    input  wire [SLOT_W-1:0]      drain_slot,
    input  wire [$clog2(N)-1:0]   drain_idx,
    output logic [31:0]           drain_out     // south
);

    logic [31:0] drain_cell [N];
    genvar gj;
    generate
        for (gj = 0; gj < N; gj++) begin : col
            // In the hierarchical flow mac_cell is a hard macro (a
            // parameterless .lib blackbox) with TMEM_SLOTS=4 / SLOT_W=2
            // baked in — so the override is sim/elaboration-only.
`ifdef SYNTHESIS
            mac_cell u_cell (
`else
            mac_cell #(.TMEM_SLOTS(TMEM_SLOTS), .SLOT_W(SLOT_W)) u_cell (
`endif
                .clk(clk), .rst(rst),
                .en(en), .zero(zero), .slot(slot),
                .a_f32(a_f32),
                .b_f32(b_f32_flat[gj*32 +: 32]),
                .drain_slot(drain_slot),
                .drain_out(drain_cell[gj])
            );
        end
    endgenerate

    assign drain_out = drain_cell[drain_idx];

endmodule

`default_nettype wire
