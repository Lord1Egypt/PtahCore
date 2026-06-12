// clk_spine — the traveling-clock generator (CHIP_SPEC §1).
//
// One deliberate buffer chain; tap[i] comes off segment i. Physically
// the chain runs along the array edge at the row/column pitch, so
// tap-to-tap delay ≈ the contract stagger (δs west / δe north) once
// the per-segment buffer count is tuned against measured post-route
// arrivals (the standing honesty table). In simulation every tap IS
// clk_in (ptah_clkbuf is a wire), so behavior never depends on the
// stagger — only silicon does.
//
// TAPS counts usable taps; SEG_BUFS buffers per segment is the tuning
// knob (delay ≈ SEG_BUFS · buf-delay + pitch wire). tap[0] is one
// buffer from clk_in (drive isolation, near-root phase).

`default_nettype none

module clk_spine #(
    parameter int TAPS     = 32,
    parameter int SEG_BUFS = 2
) (
    input  wire             clk_in,
    output wire [TAPS-1:0]  tap
);

    // node[0] = clk_in; segment i produces node[i+1] = tap[i].
    // UNOPTFLAT waiver: bit b+1 derives from bit b through a buffer
    // instance, which the simulator sees as a whole-vector
    // self-dependency and reports as a circular-logic loop. The chain
    // is pure feed-forward (provably acyclic); iterative settling
    // converges to the same values. split_var can't break it up:
    // cocotb's --public-flat-rw makes every signal public, and public
    // vars are unsplittable.
    /* verilator lint_off UNOPTFLAT */
    wire [TAPS:0] node;
    assign node[0] = clk_in;

    generate
        for (genvar s = 0; s < TAPS; s++) begin : seg
            wire [SEG_BUFS:0] n;
            assign n[0] = node[s];
            for (genvar b = 0; b < SEG_BUFS; b++) begin : buf_chain
                ptah_clkbuf u_buf (.A(n[b]), .Y(n[b+1]));
            end
            assign node[s+1] = n[SEG_BUFS];
            assign tap[s]    = node[s+1];
        end
    endgenerate
    /* verilator lint_on UNOPTFLAT */

endmodule

`default_nettype wire
