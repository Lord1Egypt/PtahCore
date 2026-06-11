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

    // ── stage 1: multiply (combinational), register the FULL product ──
    // The whole fp32 multiply (24×24 + normalize + round) is one stage and
    // its result is registered, so stage 2 is the accumulate ALONE. This
    // is the balanced split: post-place the multiply is < the adder, so the
    // adder is the lone critical path — exactly what we want to attack.
    // (Registering the raw product instead would drag the mul's normalize
    // into the add stage and make it the longer one — measured worse.)
    logic [31:0] prod;
    fp32_mul u_mul (.a(a_f32), .b(b_f32), .y(prod));

    logic [31:0]      prod_q;
    logic             en_q, zero_q;
    logic [SLOT_W-1:0] slot_q;
    always_ff @(posedge clk) begin
        if (rst) begin
            prod_q <= 32'h0; en_q <= 1'b0; zero_q <= 1'b0; slot_q <= '0;
        end else begin
            prod_q <= prod;
            en_q   <= en;
            zero_q <= zero;
            slot_q <= slot;
        end
    end

    // ── stage 2: accumulate the registered product ───────────────────
    // acc[slot] += prod_q. This is a LOOP-CARRIED dependency (each K-step
    // reads the accumulator the previous step wrote), so it cannot be
    // pipelined: a dependent accumulate chain runs no faster than one fp32
    // add. That single add (~5.3 ns at ASAP7) is the cell's clock floor.
    // Reaching 250 MHz needs a different accumulator (Kulisch fixed-point);
    // see docs/HARDENING.md.
    logic [31:0] acc_in, sum;
    assign acc_in = zero_q ? 32'h0 : acc[slot_q];
    fp32_add u_add (.a(acc_in), .b(prod_q), .y(sum));

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
