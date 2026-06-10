// fp32_add — combinational IEEE-754 single-precision add, RNE.
//
// Full alignment adder with guard/sticky, normalization shift, and
// round-to-nearest-even — bit-exact against numpy float32 addition.
//
// Scope (same contract as fp32_mul): subnormal inputs/outputs are out
// of scope — PtahCore accumulator values are sums of fp8 products
// (multiples of 2^-32 at smallest), never within 2^-126 of zero.
// Zero / inf / NaN handled. (+0)+(-0) = +0 per RNE mode.
//
// Internal fixed-point format: 28-bit {C, M[23:0], G, R, S} where the
// large operand's hidden-1 sits at bit 26. Classic FP-adder lemma:
// a left-normalization shift > 1 only happens when the alignment
// distance was <= 1, in which case no sticky bits were ever shifted
// out — so shifting the (zero) GRS field left is exact.

`default_nettype none

module fp32_add (
    input  wire  [31:0] a,
    input  wire  [31:0] b,
    output logic [31:0] y
);

    logic        sa, sb;
    logic [7:0]  ea, eb;
    logic [22:0] fa, fb;
    logic        az, bz, an, bn, ai, bi;

    logic        sl, ss;            // signs of larger / smaller operand
    logic [7:0]  el;
    logic [23:0] ml, ms;
    logic [7:0]  d;
    logic [27:0] big, algn, sum;   // {carry, man(24), G, R, S}
    logic [50:0] shifted;           // alignment with sticky collection
    logic        sub;
    int          p;                 // MSB position of sum
    logic [27:0] norm;
    logic signed [9:0] exp;
    logic [22:0] man_out;
    logic        g, s_bit, round_up;
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

        // defaults to satisfy combinational completeness
        sl = 1'b0; ss = 1'b0; el = 8'h0; ml = 24'h0; ms = 24'h0; d = 8'h0;
        big = 28'h0; algn = 28'h0; sum = 28'h0; shifted = 51'h0;
        sub = 1'b0; p = 0; norm = 28'h0; exp = 10'sd0;
        man_out = 23'h0; g = 1'b0; s_bit = 1'b0; round_up = 1'b0;
        man_rnd = 25'h0;
        y = 32'h0;

        if (an || bn || (ai && bi && (sa != sb))) begin
            y = 32'h7FC00000;                       // qNaN (incl. inf - inf)
        end else if (ai) begin
            y = {sa, 8'hFF, 23'h0};
        end else if (bi) begin
            y = {sb, 8'hFF, 23'h0};
        end else if (az && bz) begin
            y = {sa & sb, 31'h0};                   // +0 unless both are -0
        end else if (az) begin
            y = b;
        end else if (bz) begin
            y = a;
        end else begin
            // order by magnitude: larger operand drives sign and exponent
            if ({ea, fa} >= {eb, fb}) begin
                sl = sa; el = ea; ml = {1'b1, fa};
                ss = sb;          ms = {1'b1, fb};
                d  = ea - eb;
            end else begin
                sl = sb; el = eb; ml = {1'b1, fb};
                ss = sa;          ms = {1'b1, fa};
                d  = eb - ea;
            end

            big = {1'b0, ml, 3'b000};               // hidden-1 at bit 26

            // align smaller mantissa; everything below R ORs into sticky
            if (d >= 8'd27) begin
                algn = {27'b0, |ms};
            end else begin
                shifted = {ms, 27'b0} >> d;
                algn   = {1'b0, shifted[50:25], |shifted[24:0]};
            end

            sub = (sl != ss);
            sum = sub ? (big - algn) : (big + algn);

            if (sum == 28'b0) begin
                y = 32'h0;                          // exact cancellation → +0
            end else begin
                // locate MSB
                p = 0;
                for (int k = 27; k >= 0; k--) begin
                    if (sum[k]) begin p = k; break; end
                end

                if (p == 27) begin
                    // carry out: conceptual right-shift by 1; fold into sticky
                    man_out = sum[26:4];
                    g       = sum[3];
                    s_bit   = sum[2] | sum[1] | sum[0];
                    exp     = $signed({2'b0, el}) + 10'sd1;
                end else begin
                    norm    = sum << (26 - p);      // GRS exact when shift > 1
                    man_out = norm[25:3];
                    g       = norm[2];
                    s_bit   = norm[1] | norm[0];
                    exp     = $signed({2'b0, el}) - $signed(10'(26 - p));
                end

                // round-to-nearest-even
                round_up = g && (s_bit || man_out[0]);
                man_rnd  = {2'b01, man_out} + {24'b0, round_up};
                if (man_rnd[24]) begin
                    man_out = man_rnd[23:1];
                    exp     = exp + 10'sd1;
                end else begin
                    man_out = man_rnd[22:0];
                end

                if (exp >= 10'sd255)     y = {sl, 8'hFF, 23'h0};   // → inf
                else if (exp <= 10'sd0)  y = {sl, 31'h0};          // (unreached)
                else                     y = {sl, exp[7:0], man_out};
            end
        end
    end

endmodule

`default_nettype wire
