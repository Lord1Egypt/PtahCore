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
    input  wire  [31:0] a,
    input  wire  [31:0] b,
    output logic [31:0] y
);

    // unpack
    logic        sa, sb, sy;
    logic [7:0]  ea, eb;
    logic [22:0] fa, fb;
    logic        az, bz, an, bn, ai, bi;   // zero / nan / inf

    logic [23:0] ma, mb;
    logic [47:0] raw;
    logic signed [9:0] exp;                // wide signed working exponent
    logic [22:0] man_out;
    logic        guard, sticky, round_up;
    logic [24:0] man_rnd;

    always_comb begin
        {sa, ea, fa} = a;
        {sb, eb, fb} = b;
        az = (ea == 8'h00) && (fa == 23'h0);
        bz = (eb == 8'h00) && (fb == 23'h0);
        an = (ea == 8'hFF) && (fa != 23'h0);
        bn = (eb == 8'hFF) && (fb != 23'h0);
        ai = (ea == 8'hFF) && (fa == 23'h0);
        bi = (eb == 8'hFF) && (fb == 23'h0);
        sy = sa ^ sb;

        // defaults — every always_comb variable assigned on every path
        ma = 24'h0; mb = 24'h0; raw = 48'h0; exp = 10'sd0;
        man_out = 23'h0; guard = 1'b0; sticky = 1'b0;
        round_up = 1'b0; man_rnd = 25'h0;
        y = 32'h0;

        if (an || bn || (ai && bz) || (bi && az)) begin
            y = 32'h7FC00000;                       // qNaN
        end else if (ai || bi) begin
            y = {sy, 8'hFF, 23'h0};                 // inf
        end else if (az || bz) begin
            y = {sy, 31'h0};                        // signed zero
        end else begin
            ma  = {1'b1, fa};
            mb  = {1'b1, fb};
            raw = ma * mb;                          // 48-bit product
            exp = $signed({2'b0, ea}) + $signed({2'b0, eb}) - 10'sd127;

            // normalize: product in [1,4) → top bit at 47 or 46
            if (raw[47]) begin
                man_out = raw[46:24];
                guard   = raw[23];
                sticky  = |raw[22:0];
                exp     = exp + 10'sd1;
            end else begin
                man_out = raw[45:23];
                guard   = raw[22];
                sticky  = |raw[21:0];
            end

            // round-to-nearest-even
            round_up = guard && (sticky || man_out[0]);
            man_rnd  = {2'b01, man_out} + {24'b0, round_up};
            if (man_rnd[24]) begin                  // rounding overflowed
                man_out = man_rnd[23:1];
                exp     = exp + 10'sd1;
            end else begin
                man_out = man_rnd[22:0];
            end

            if (exp >= 10'sd255) y = {sy, 8'hFF, 23'h0};      // overflow → inf
            else if (exp <= 10'sd0) y = {sy, 31'h0};          // (can't happen w/ fp8 inputs)
            else y = {sy, exp[7:0], man_out};
        end
    end

endmodule

`default_nettype wire
