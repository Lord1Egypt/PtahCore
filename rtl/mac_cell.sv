// mac_cell — one (i, j) leaf of the compute array.
//
// Holds TMEM_SLOTS fp32 accumulators. Per asserted `en` cycle:
//     acc[slot] <= (zero ? 0 : acc[slot]) + a_f32 * b_f32
// Operands arrive already decoded to fp32 (the decode is shared per
// row/column at the array edge — 64 decoders, not 2048).
//
// The fp32 multiply-add here is behavioral (`shortreal`-free, bit-true
// via $bitstoshortreal equivalent using DPI-free real conversion is not
// synthesis-clean, so we implement an exact single-precision FMA-free
// mul-then-add datapath in synthesizable logic).
//
// v1 datapath: mul and add are performed in two stages combinationally
// within the cycle (synthesis will retime). Rounding: nearest-even,
// matching numpy float32 semantics — verified bit-exact by cocotb
// against the pymodel.
//
// drain interface: when `drain_en` is high, `drain_out` presents
// acc[drain_slot] combinationally (the array muxes one cell per cycle).

`default_nettype none

module mac_cell #(
    parameter int TMEM_SLOTS = 4,
    parameter int SLOT_W     = 2
) (
    input  wire               clk,
    input  wire               rst,

    input  wire               en,        // do one MAC this cycle
    input  wire               zero,      // zero accumulator before MAC
    input  wire [SLOT_W-1:0]  slot,
    input  wire [31:0]        a_f32,
    input  wire [31:0]        b_f32,

    input  wire [SLOT_W-1:0]  drain_slot,
    output logic [31:0]       drain_out
);

    logic [31:0] acc [TMEM_SLOTS];

    // fp32 multiply (exact for fp8 inputs — products fit in 8+ man bits)
    logic [31:0] prod;
    fp32_mul u_mul (.a(a_f32), .b(b_f32), .y(prod));

    // fp32 add: acc + prod, nearest-even
    logic [31:0] acc_in, sum;
    assign acc_in = zero ? 32'h0 : acc[slot];
    fp32_add u_add (.a(acc_in), .b(prod), .y(sum));

    always_ff @(posedge clk) begin
        if (rst) begin
            for (int s = 0; s < TMEM_SLOTS; s++) acc[s] <= 32'h0;
        end else if (en) begin
            acc[slot] <= sum;
        end
    end

    assign drain_out = acc[drain_slot];

endmodule

`default_nettype wire
