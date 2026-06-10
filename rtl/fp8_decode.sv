// fp8_decode — combinational fp8 (e4m3 / e5m2) → fp32 decoder.
//
// Pure combinational: one fp8 byte in, IEEE-754 single out, same cycle.
// Both OCP formats, selected by `fmt` (0 = e4m3, 1 = e5m2).
//
// e4m3: bias 7,  4 exp / 3 man. S.1111.111 is the only NaN; no inf.
// e5m2: bias 15, 5 exp / 2 man. IEEE-like: exp=31 → inf (man=0) / NaN.
//
// Every fp8 value is exactly representable in fp32, so this is a pure
// re-encoding: subnormal mantissas are normalized with a leading-zero
// shift folded into the exponent.

`default_nettype none

module fp8_decode (
    input  wire [7:0]  in8,
    input  wire        fmt,      // 0 = e4m3, 1 = e5m2
    output logic [31:0] out
);

    logic        sign;
    logic [4:0]  exp;            // widest of the two formats
    logic [2:0]  man;
    logic        is_zero, is_nan, is_inf, is_sub;

    // fp32 fields
    logic [7:0]  f32_exp;
    logic [22:0] f32_man;

    always_comb begin
        sign = in8[7];

        if (fmt == 1'b0) begin // ── e4m3 ─────────────────────────────
            exp = {1'b0, in8[6:3]};
            man = in8[2:0];
            is_nan  = (in8[6:0] == 7'h7F);          // S.1111.111 only
            is_inf  = 1'b0;
            is_zero = (in8[6:0] == 7'h00);
            is_sub  = (exp == 5'd0) && !is_zero;

            if (is_nan) begin
                f32_exp = 8'hFF; f32_man = 23'h400000;       // qNaN
            end else if (is_zero) begin
                f32_exp = 8'h00; f32_man = 23'h0;
            end else if (is_sub) begin
                // value = man/8 * 2^-6 → normalize by leading-zero shift
                unique casez (man)
                    3'b1??: begin f32_exp = 8'd127 - 8'd7;  f32_man = {man[1:0], 21'b0}; end
                    3'b01?: begin f32_exp = 8'd127 - 8'd8;  f32_man = {man[0], 22'b0};   end
                    3'b001: begin f32_exp = 8'd127 - 8'd9;  f32_man = 23'b0;             end
                    default: begin f32_exp = 8'h00;         f32_man = 23'b0;             end
                endcase
            end else begin
                f32_exp = 8'd127 - 8'd7 + {3'b0, exp};
                f32_man = {man, 20'b0};
            end

        end else begin        // ── e5m2 ─────────────────────────────
            exp = in8[6:2];
            man = {1'b0, in8[1:0]};
            is_nan  = (exp == 5'h1F) && (in8[1:0] != 2'b00);
            is_inf  = (exp == 5'h1F) && (in8[1:0] == 2'b00);
            is_zero = (in8[6:0] == 7'h00);
            is_sub  = (exp == 5'd0) && !is_zero;

            if (is_nan) begin
                f32_exp = 8'hFF; f32_man = 23'h400000;
            end else if (is_inf) begin
                f32_exp = 8'hFF; f32_man = 23'h0;
            end else if (is_zero) begin
                f32_exp = 8'h00; f32_man = 23'h0;
            end else if (is_sub) begin
                // value = man/4 * 2^-14
                unique casez (in8[1:0])
                    2'b1?: begin f32_exp = 8'd127 - 8'd15; f32_man = {in8[0], 22'b0}; end
                    2'b01: begin f32_exp = 8'd127 - 8'd16; f32_man = 23'b0;          end
                    default: begin f32_exp = 8'h00;        f32_man = 23'b0;          end
                endcase
            end else begin
                f32_exp = 8'd127 - 8'd15 + {3'b0, exp};
                f32_man = {in8[1:0], 21'b0};
            end
        end

        out = {sign, f32_exp, f32_man};
    end

endmodule

`default_nettype wire
