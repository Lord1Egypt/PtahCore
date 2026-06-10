// fp32_mul — combinational IEEE-754 single-precision multiply, RNE.
//
// Scope (documented, asserted in TB): subnormal INPUTS are not
// supported — in PtahCore every operand comes from fp8_decode, whose
// smallest output is 2^-16, far above fp32's subnormal range. Subnormal
// RESULTS cannot occur for the same reason. Zero / inf / NaN handled.
//
// Rounding: round-to-nearest-even on the 48-bit raw product, matching
// numpy float32 semantics bit-for-bit (verified by cocotb).

`default_nettype none

module fp32_mul (
    input  wire         clk,
    input  wire  [31:0] a,
    input  wire  [31:0] b,
    output logic [31:0] y                  // valid 1 cycle after a/b (latency 1)
);

    // ── stage 1 (combinational): classify + 24×24 product ────────────
    // The 24×24 multiply is the long pole at 7nm, so it ends stage 1 and
    // its result is registered before normalize/round in stage 2.
    logic        sa, sb, sy1;
    logic [7:0]  ea, eb;
    logic [22:0] fa, fb;
    logic        az, bz, an, bn, ai, bi;
    logic [23:0] ma, mb;
    logic [47:0] raw1;
    logic signed [9:0] exp1;
    logic [1:0]  spec1;                     // 0 normal, 1 nan, 2 inf, 3 zero

    always_comb begin
        {sa, ea, fa} = a;
        {sb, eb, fb} = b;
        az = (ea == 8'h00) && (fa == 23'h0);
        bz = (eb == 8'h00) && (fb == 23'h0);
        an = (ea == 8'hFF) && (fa != 23'h0);
        bn = (eb == 8'hFF) && (fb != 23'h0);
        ai = (ea == 8'hFF) && (fa == 23'h0);
        bi = (eb == 8'hFF) && (fb == 23'h0);
        sy1 = sa ^ sb;
        ma  = {1'b1, fa};
        mb  = {1'b1, fb};
        raw1 = ma * mb;
        exp1 = $signed({2'b0, ea}) + $signed({2'b0, eb}) - 10'sd127;

        if (an || bn || (ai && bz) || (bi && az)) spec1 = 2'd1;   // qNaN
        else if (ai || bi)                        spec1 = 2'd2;   // inf
        else if (az || bz)                        spec1 = 2'd3;   // zero
        else                                      spec1 = 2'd0;   // normal
    end

    // ── pipeline register ────────────────────────────────────────────
    logic [47:0]       raw_q;
    logic signed [9:0] exp_q;
    logic              sy_q;
    logic [1:0]        spec_q;
    always_ff @(posedge clk) begin
        raw_q  <= raw1;
        exp_q  <= exp1;
        sy_q   <= sy1;
        spec_q <= spec1;
    end

    // ── stage 2 (combinational): normalize + round ───────────────────
    logic [22:0] man_out;
    logic        guard, sticky, round_up;
    logic [24:0] man_rnd;
    logic signed [9:0] exp;

    always_comb begin
        man_out = 23'h0; guard = 1'b0; sticky = 1'b0;
        round_up = 1'b0; man_rnd = 25'h0; exp = exp_q;
        y = 32'h0;

        unique case (spec_q)
            2'd1: y = 32'h7FC00000;                 // qNaN
            2'd2: y = {sy_q, 8'hFF, 23'h0};         // inf
            2'd3: y = {sy_q, 31'h0};                // signed zero
            default: begin
                // product in [1,4) → top bit at 47 or 46
                if (raw_q[47]) begin
                    man_out = raw_q[46:24];
                    guard   = raw_q[23];
                    sticky  = |raw_q[22:0];
                    exp     = exp_q + 10'sd1;
                end else begin
                    man_out = raw_q[45:23];
                    guard   = raw_q[22];
                    sticky  = |raw_q[21:0];
                end
                round_up = guard && (sticky || man_out[0]);
                man_rnd  = {2'b01, man_out} + {24'b0, round_up};
                if (man_rnd[24]) begin
                    man_out = man_rnd[23:1];
                    exp     = exp + 10'sd1;
                end else begin
                    man_out = man_rnd[22:0];
                end
                if (exp >= 10'sd255)    y = {sy_q, 8'hFF, 23'h0};
                else if (exp <= 10'sd0) y = {sy_q, 31'h0};
                else                    y = {sy_q, exp[7:0], man_out};
            end
        endcase
    end

endmodule

`default_nettype wire
