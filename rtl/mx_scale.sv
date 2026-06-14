// mx_scale — MXFP8 drain-time scale: a pure fp32 EXPONENT ADD + saturate.
// Twin: golden/mxfp8.py `_scale_one_bits` / pymodel MacArray.drain_read.
//
// The shared E8M0 block scale is a power of two (value 2^(X-127)), so
// scaling the fp32 accumulator is just adding (ea-127)+(eb-127) to its
// exponent field — never a multiply. This is the whole MX hardware cost,
// and it lives on the drain/store path, NOT in the 1024 MAC cells.
//
// COMBINATIONAL by contract: adding a register here would change the drain
// latency (store.sv DRAIN_LAT, the mac_array drain timing, every e2e
// expectation). en=0 ⇒ out == in, bit-identical to the pre-Phase-8 path.
//
// Saturation (identical to the golden branches):
//   en=0                         → passthrough (mx off)
//   ea or eb == 0xFF (E8M0 NaN)  → canonical fp32 qNaN
//   in exp field == 0xFF         → passthrough (accumulator inf/NaN)
//   in exp field == 0x00         → flush to signed zero (zero/subnormal)
//   new exponent >= 0xFF         → ±inf (overflow)
//   new exponent <= 0            → ±0   (underflow)
//   else                         → {sign, new_exp, mantissa}  (exact)

`default_nettype none

module mx_scale (
    input  wire [31:0] in32,
    input  wire [7:0]  ea,       // E8M0 scale for this output row    (A)
    input  wire [7:0]  eb,       // E8M0 scale for this output column (B)
    input  wire        en,       // mx enable (0 = passthrough)
    output logic [31:0] out32
);
    wire        sign = in32[31];
    wire [7:0]  exp  = in32[30:23];
    wire [22:0] mant = in32[22:0];
    wire        nan_scale = (ea == 8'hFF) || (eb == 8'hFF);

    // new exponent = exp + (ea-127) + (eb-127), signed with headroom
    // range: [-254, +511] → fits signed 11 bits
    wire signed [10:0] new_exp =
          $signed({3'b000, exp})
        + $signed({3'b000, ea})
        + $signed({3'b000, eb})
        - 11'sd254;

    always_comb begin
        if (!en)                       out32 = in32;
        else if (nan_scale)            out32 = 32'h7FC00000;          // qNaN
        else if (exp == 8'hFF)         out32 = in32;                  // inf/NaN
        else if (exp == 8'h00)         out32 = {sign, 31'b0};         // ±0
        else if (new_exp >= 11'sd255)  out32 = {sign, 8'hFF, 23'b0};  // ±inf
        else if (new_exp <= 11'sd0)    out32 = {sign, 31'b0};         // ±0
        else                           out32 = {sign, new_exp[7:0], mant};
    end
endmodule

`default_nettype wire
