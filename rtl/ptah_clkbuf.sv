// ptah_clkbuf — the spine's buffer element (tech wrapper).
//
// The ONE file that names a standard cell: synthesis instantiates the
// ASAP7 clock-grade buffer directly (the spine is deliberate physical
// structure — CTS must never balance it, the resizer must never touch
// it; the chip flow marks instances of this wrapper dont_touch). In
// simulation it is a zero-delay wire, so every spine tap is literally
// the chip clock and the RTL is cycle-identical to the pre-spine
// design — the stagger is physics, not behavior (ARRAY_SPEC §2).

`default_nettype none

`ifdef SYNTHESIS
(* keep_hierarchy *)
module ptah_clkbuf (
    input  wire A,
    output wire Y
);
    (* keep *) BUFx24_ASAP7_75t_R u_buf (.A(A), .Y(Y));
endmodule

(* blackbox *)
module BUFx24_ASAP7_75t_R (
    input  wire A,
    output wire Y
);
endmodule
`else
module ptah_clkbuf (
    input  wire A,
    output wire Y
);
    assign Y = A;
endmodule
`endif

`default_nettype wire
