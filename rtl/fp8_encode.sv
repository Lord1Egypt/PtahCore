// fp8_encode — combinational fp32 → fp8 e4m3, RNE, saturating.
//
// Golden twin: golden/fp8.py encode(value, "e4m3"). Policy:
//   NaN            → 0x7F (canonical NaN)
//   ±inf, |v|>max  → ±0x7E (saturate to ±448; e4m3 has no inf)
//   |v| < min sub/2 (2^-10) → ±0 (RNE rounds to zero)
//   otherwise      → nearest-even among the 256 encodings
//
// Normal e4m3 range: exponent e in [-6, 8] (bias 7), 3-bit mantissa.
// Subnormal: value = m/8 * 2^-6, m in 1..7 (i.e. multiples of 2^-9).
//
// fp32 subnormal inputs are treated as zero (they're 2^-126-scale,
// astronomically below e4m3's 2^-10 round-to-zero threshold).

`default_nettype none

module fp8_encode (
    input  wire  [31:0] in32,
    output logic [7:0]  out8
);

    logic        sign;
    logic [7:0]  exp;
    logic [22:0] frac;
    logic        is_nan, is_inf, is_zero_or_sub;
    logic signed [9:0] e;            // unbiased exponent
    logic [23:0] man;                // {1, frac}
    logic [4:0]  shift;
    logic [47:0] sh;                 // man aligned for subnormal rounding
    logic [3:0]  man4;               // 3 mantissa bits + overflow bit
    logic        g, s_bit;
    logic [3:0]  exp4;

    always_comb begin
        {sign, exp, frac} = in32;
        is_nan         = (exp == 8'hFF) && (frac != 23'h0);
        is_inf         = (exp == 8'hFF) && (frac == 23'h0);
        is_zero_or_sub = (exp == 8'h00);
        e   = $signed({2'b0, exp}) - 10'sd127;
        man = {1'b1, frac};

        // defaults
        shift = 5'd0; sh = 48'h0; man4 = 4'h0;
        g = 1'b0; s_bit = 1'b0; exp4 = 4'h0;
        out8 = 8'h00;

        if (is_nan) begin
            out8 = 8'h7F;
        end else if (is_inf || e > 10'sd8) begin
            out8 = {sign, 7'h7E};                       // saturate ±448
        end else if (is_zero_or_sub || e < -10'sd10) begin
            out8 = {sign, 7'h00};                       // → ±0
        end else if (e == 10'sd8) begin
            // top binade: codes 1111.000..110 only — 1111.111 is the NaN
            // encoding, so any round to m≥7 saturates to ±448 (0x7E)
            man4  = {1'b0, man[22:20]};
            g     = man[19];
            s_bit = |man[18:0];
            man4  = man4 + {3'b0, g & (s_bit | man4[0])};
            if (man4 >= 4'd7) out8 = {sign, 7'h7E};
            else              out8 = {sign, 4'd15, man4[2:0]};
        end else if (e >= -10'sd6) begin
            // normal range: exp4 = e + 7 in [1, 14]
            man4  = {1'b0, man[22:20]};
            g     = man[19];
            s_bit = |man[18:0];
            man4  = man4 + {3'b0, g & (s_bit | man4[0])};
            exp4  = 4'(e + 10'sd7);
            if (man4[3]) begin                          // mantissa overflow
                exp4 = exp4 + 4'd1;                     // e+7 ≤ 14 ⇒ ≤ 15, safe
                man4 = 4'b0000;
            end
            out8 = {sign, exp4, man4[2:0]};
        end else begin
            // subnormal target: result = round(man · 2^(e+9)) units of 2^-9
            // e in [-10, -7] ⇒ keep top (e+10) bits of man as integer part
            shift = 5'(10'sd23 - (e + 10'sd9));         // bits below integer pt
            sh    = {24'h0, man};
            // integer part = man >> shift, guard = bit shift-1, sticky below
            man4  = 4'(sh >> shift);
            g     = sh[shift-1];
            s_bit = |(sh & ((48'h1 << (shift-1)) - 48'h1));
            man4  = man4 + {3'b0, g & (s_bit | man4[0])};
            if (man4[3]) out8 = {sign, 4'd1, 3'b000};   // rounds up to min normal
            else         out8 = {sign, 4'd0, man4[2:0]};
        end
    end

endmodule

`default_nettype wire
