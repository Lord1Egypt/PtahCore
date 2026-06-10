// smem — on-chip operand scratchpad. 1 write port, 2 read ports.
//
// Pymodel twin: pymodel/smem.py. Behavioral byte array in v1 sim;
// hardening (Phase 6+) remaps this to SRAM macros behind the same ports.
//
// Ports
//   write : 16 B/cycle, 16-byte-aligned address (LOAD's DMA beat width)
//   read A / read B : 32 B/cycle each, registered (data valid next
//     cycle) — sized for one operand column per K-step at the array
//     edge. Two ports so A and B columns stream in the same cycle.
//
// The barrier region (first BARRIER_REGION bytes) is owned by the
// barrier file, which has its own state — writes below the region are
// a software error, asserted here exactly like the pymodel twin.

`default_nettype none

module smem #(
    parameter int SMEM_BYTES     = 65536,
    parameter int BARRIER_REGION = 256,
    parameter int RD_BYTES       = 32,
    parameter int WR_BYTES       = 16
) (
    input  wire                       clk,

    input  wire                       wr_en,
    input  wire  [$clog2(SMEM_BYTES)-1:0] wr_addr,     // 16-B aligned
    input  wire  [WR_BYTES*8-1:0]     wr_data,         // byte 0 = lowest addr

    input  wire  [$clog2(SMEM_BYTES)-1:0] rd_a_addr,
    output logic [RD_BYTES*8-1:0]     rd_a_data,       // valid next cycle

    input  wire  [$clog2(SMEM_BYTES)-1:0] rd_b_addr,
    output logic [RD_BYTES*8-1:0]     rd_b_data
);

    logic [7:0] mem [SMEM_BYTES];

    always_ff @(posedge clk) begin
        if (wr_en) begin
`ifndef SYNTHESIS
            assert (32'(wr_addr) >= BARRIER_REGION)
                else $fatal(1, "smem write into barrier region: %0d", wr_addr);
            assert (wr_addr[3:0] == 4'h0)
                else $fatal(1, "smem write not 16-B aligned: %0d", wr_addr);
`endif
            for (int i = 0; i < WR_BYTES; i++)
                mem[32'(wr_addr) + i] <= wr_data[i*8 +: 8];
        end

        for (int i = 0; i < RD_BYTES; i++) begin
            rd_a_data[i*8 +: 8] <= mem[32'(rd_a_addr) + i];
            rd_b_data[i*8 +: 8] <= mem[32'(rd_b_addr) + i];
        end
    end

endmodule

`default_nettype wire
