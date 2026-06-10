// mac_cell — one (i, j) leaf of the compute array. TWO-STAGE PIPELINE.
//
// Holds TMEM_SLOTS fp32 accumulators. Operands arrive already decoded to
// fp32 (decode is shared per row/column at the array edge).
//
//   stage 1 (cycle N):   prod_q <= a_f32 * b_f32            (+ latch ctrl)
//   stage 2 (cycle N+1):  acc[slot] <= (zero ? 0 : acc[slot]) + prod_q
//
// Why pipelined: at ASAP7 the combinational fp32 multiply→add→accumulate
// chain is ~6.24 ns — it can't close 250 MHz (Phase 6a measured
// WNS −2237 ps). Registering the product splits it into a ~3.7 ns multiply
// stage and a ~2.5 ns add-stage, both under the 4 ns budget. The control
// (en/zero/slot) is delayed one cycle to line up with the registered
// product, so the result is bit-identical — just one cycle later.
//
// The extra latency is absorbed by mac_array, which runs one flush cycle
// after the last K-column so the final product reaches the accumulator
// before `done`. Value semantics are unchanged → still bit-exact vs golden.
//
// drain interface: `drain_out` presents acc[drain_slot] combinationally
// (the array muxes one cell per cycle for STORE).

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

    // ── stages 1–2: pipelined multiply (latency 1) ───────────────────
    // fp32_mul registers the 24×24 product internally, so `prod` is valid
    // one cycle after a_f32/b_f32 and the long multiply no longer shares a
    // cycle with the adder.
    logic [31:0] prod;                                 // valid at N+1
    fp32_mul u_mul (.clk(clk), .a(a_f32), .b(b_f32), .y(prod));

    // Control is delayed one cycle to line up with `prod` (operand→acc
    // latency = 2: one cycle in the multiply, one in the accumulate).
    logic             en_q, zero_q;
    logic [SLOT_W-1:0] slot_q;
    always_ff @(posedge clk) begin
        if (rst) begin
            en_q <= 1'b0; zero_q <= 1'b0; slot_q <= '0;
        end else begin
            en_q <= en; zero_q <= zero; slot_q <= slot;
        end
    end

    // ── stage 3: accumulate the product (combinational add → register) ─
    logic [31:0] acc_in, sum;
    assign acc_in = zero_q ? 32'h0 : acc[slot_q];
    fp32_add u_add (.a(acc_in), .b(prod), .y(sum));

    always_ff @(posedge clk) begin
        if (rst) begin
            for (int s = 0; s < TMEM_SLOTS; s++) acc[s] <= 32'h0;
        end else if (en_q) begin
            acc[slot_q] <= sum;
        end
    end

    assign drain_out = acc[drain_slot];

endmodule

`default_nettype wire
