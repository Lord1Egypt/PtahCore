// mac_row — one 1×N row of mac_tiles: the physical tiling unit.
//
// docs/TILE_SPEC.md builds the 32×32 array out of abutted tiles. The row
// chains N mac_tiles west→east: clock, reset, control (en/zero/slot/
// drain_slot), the row's A operand and the row_hit select all enter the
// row's west edge ONCE and travel tile-to-tile through the feedthroughs —
// the parent routes nothing over the tiles (TILE_SPEC §5). Each tile takes
// its own column B operand on its north edge.
//
// Drain: the standalone row ties row_hit_in = 1 / drain_n_in = 0 on every
// tile, so each tile presents its own accumulator on its south edge; the
// drain_idx → drain_out column mux below sits OUTSIDE the tiles (at chip
// scale it lives south of the array, with STORE). When rows stack into the
// array, row_hit comes from the west-edge row decoder and the south edges
// chain into the next row's drain_n_in instead.
//
// In simulation the feedthroughs are zero-delay wires, so the row is
// bit-identical to N bare mac_cells — every cell behaves exactly as it
// did when mac_array instantiated it directly.

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
    input  wire [31:0]            a_f32,        // row operand (west)
    input  wire [N*32-1:0]        b_f32_flat,   // per-column operand (north)

    input  wire [SLOT_W-1:0]      drain_slot,
    input  wire [$clog2(N)-1:0]   drain_idx,
    output logic [31:0]           drain_out     // south, REGISTERED (1 cycle)
);

    // West→east traveling nets: element j drives tile j's west edge;
    // tile j's east edge drives element j+1. Element 0 is the row input.
    wire              t_clk      [N+1];
    wire              t_rst      [N+1];
    wire              t_en       [N+1];
    wire              t_zero     [N+1];
    wire [SLOT_W-1:0] t_slot     [N+1];
    wire [SLOT_W-1:0] t_dslot    [N+1];
    wire              t_hit      [N+1];
    wire [31:0]       t_a        [N+1];

    assign t_clk[0]   = clk;
    assign t_rst[0]   = rst;
    assign t_en[0]    = en;
    assign t_zero[0]  = zero;
    assign t_slot[0]  = slot;
    assign t_dslot[0] = drain_slot;
    assign t_hit[0]   = 1'b1;       // standalone row: always selected
    assign t_a[0]     = a_f32;

    logic [31:0] drain_cell [N];
    genvar gj;
    generate
        for (gj = 0; gj < N; gj++) begin : col
            // In the hierarchical flow mac_tile is a hard macro (a
            // parameterless .lib blackbox) with TMEM_SLOTS=4 / SLOT_W=2
            // baked in — so the override is sim/elaboration-only.
`ifdef SYNTHESIS
            mac_tile u_tile (
`else
            mac_tile #(.TMEM_SLOTS(TMEM_SLOTS), .SLOT_W(SLOT_W)) u_tile (
`endif
                .clk_in(t_clk[gj]),   .clk_out(t_clk[gj+1]),
                .rst_in(t_rst[gj]),   .rst_out(t_rst[gj+1]),
                .en_in(t_en[gj]),     .en_out(t_en[gj+1]),
                .zero_in(t_zero[gj]), .zero_out(t_zero[gj+1]),
                .slot_in(t_slot[gj]), .slot_out(t_slot[gj+1]),
                .drain_slot_in(t_dslot[gj]), .drain_slot_out(t_dslot[gj+1]),
                .row_hit_in(t_hit[gj]),      .row_hit_out(t_hit[gj+1]),
                .a_in(t_a[gj]),       .a_out(t_a[gj+1]),
                .b_in(b_f32_flat[gj*32 +: 32]),
                .b_out(),                       // south (row stacking)
                .drain_n_in(32'h0),
                .drain_s_out(drain_cell[gj])
            );
        end
    endgenerate

    // Registered drain: with the traveling clock, a far tile launches its
    // accumulator on a clock that has traveled ~3 ns east — a combinational
    // mux→port return measured −416 ps at the row boundary (honest single-
    // cycle failure, ASAP7 P&R). The row-top register breaks that path:
    // late-launch→flop fits the cycle, flop→port is trivial. Drain reads
    // are now presented one cycle after drain_idx; STORE's write-back
    // stage absorbs the latency.
    always_ff @(posedge clk) begin
        drain_out <= drain_cell[drain_idx];
    end

endmodule

`default_nettype wire
