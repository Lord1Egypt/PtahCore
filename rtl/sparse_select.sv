// sparse_select — 2:4 metadata-driven 2-of-4 lane selector (Phase 9b).
//
// The reusable hardware primitive for 2:4 structured sparsity: given a
// 4-lane operand window and one group's metadata byte (two 2-bit kept-lane
// indices, idx0 = meta[1:0], idx1 = meta[3:2]; see golden/sparse24.py),
// drive out the two selected lanes. Combinational — no latency.
//
// This is exactly the mux a sparse-capable mac_cell instantiates: in the
// broadcast array each cell sees the 4 B lanes of a K-group and selects the
// 2 that pair with its row's two kept A values. The eventual array
// integration (docs/SPARSITY.md) wires one of these per cell with the
// per-row metadata; verified here in isolation against the golden twin so
// the datapath block is proven before the (GDS-invalidating) array rewrite.
//
// W is the lane width: 32 for fp32 operands, 8 for fp8 bytes — the same
// select serves either. mx=0/sparse=0 paths never instantiate this, so the
// dense array stays bit-identical.

`default_nettype none

module sparse_select #(
    parameter int W = 32
) (
    input  wire [4*W-1:0] win,    // 4 lanes, lane p at win[p*W +: W]
    input  wire [3:0]     meta,   // idx0 = meta[1:0], idx1 = meta[3:2]
    output logic [W-1:0]  sel0,   // win[idx0]
    output logic [W-1:0]  sel1    // win[idx1]
);
    wire [1:0] idx0 = meta[1:0];
    wire [1:0] idx1 = meta[3:2];
    assign sel0 = win[idx0*W +: W];
    assign sel1 = win[idx1*W +: W];
endmodule

`default_nettype wire
