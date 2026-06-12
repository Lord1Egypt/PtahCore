// fakeram7_256x256 — 8 KiB 1RW SRAM macro (FakeRAM2.0, ASAP7 platform).
//
// Hardening consumes the platform's .lib/.lef via the BLOCKS flow; this
// file is (a) a synthesis blackbox so elaboration sees the macro
// boundary, and (b) a clean behavioral twin for Verilator (the
// platform's .v corrupts the array on X and ORs write data into the
// word — generator quirks we neither need nor want to model).
//
// Contract as used by smem_phys: ce_in gates everything; on we_in the
// addressed word is overwritten; rd_out the cycle after a write is
// never relied on (smem_phys stalls colliding readers instead).

`default_nettype none

`ifdef SYNTHESIS
(* blackbox *)
module fakeram7_256x256 (
    output logic [255:0] rd_out,
    input  wire  [7:0]   addr_in,
    input  wire          we_in,
    input  wire  [255:0] wd_in,
    input  wire          clk,
    input  wire          ce_in
);
endmodule
`else
module fakeram7_256x256 (
    output logic [255:0] rd_out,
    input  wire  [7:0]   addr_in,
    input  wire          we_in,
    input  wire  [255:0] wd_in,
    input  wire          clk,
    input  wire          ce_in
);
    logic [255:0] mem [256];

    always_ff @(posedge clk) begin
        if (ce_in) begin
            if (we_in) mem[addr_in] <= wd_in;
            rd_out <= mem[addr_in];   // pre-write word on a write cycle
        end
    end
endmodule
`endif

`default_nettype wire
