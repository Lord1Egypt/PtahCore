// load — async DMA engine, gmem → smem. Pymodel twin: pymodel/load.py.
//
// One 16-byte beat per cycle. GMEM is external: the engine drives a
// read address and expects data combinationally that cycle (the chip
// TB / memory controller owns latency; v1 contract is 1-cycle).
//
// Barrier protocol (exactly the pymodel's):
//   issue-time  : cmdproc raises bar.tx += nbytes THE SAME CYCLE it
//                 pulses start (the barrier file's tx port belongs to
//                 the cmdproc, keeping issue atomic).
//   completion  : this engine pulses done with tx_done = nbytes; the
//                 barrier applies tx -= nbytes, pending -= 1, flip.
//
// start while busy is a cmdproc contract violation (asserted).

`default_nettype none

module load #(
    parameter int BYTES_PER_CYCLE = 16,
    parameter int SMEM_AW = 16,
    parameter int GMEM_AW = 32
) (
    input  wire                clk,
    input  wire                rst,

    input  wire                start,
    input  wire [3:0]          start_bar,
    input  wire [GMEM_AW-1:0]  start_gmem,
    input  wire [SMEM_AW-1:0]  start_smem,
    input  wire [31:0]         start_nbytes,    // multiple of 16

    output logic               busy,
    output logic               done,            // 1-cycle pulse
    output logic [3:0]         done_bar,
    output logic [31:0]        done_txbytes,

    // gmem read (combinational data return, TB contract)
    output logic [GMEM_AW-1:0] gmem_rd_addr,
    input  wire  [BYTES_PER_CYCLE*8-1:0] gmem_rd_data,

    // smem write port
    output logic               smem_wr_en,
    output logic [SMEM_AW-1:0] smem_wr_addr,
    output logic [BYTES_PER_CYCLE*8-1:0] smem_wr_data
);

    logic [3:0]         bar_q;
    logic [GMEM_AW-1:0] g_q;
    logic [SMEM_AW-1:0] s_q;
    logic [31:0]        n_q, cur_q;

    // current beat (combinational read-through gmem→smem)
    assign gmem_rd_addr = g_q + cur_q[GMEM_AW-1:0];
    assign smem_wr_en   = busy;
    assign smem_wr_addr = s_q + cur_q[SMEM_AW-1:0];
    assign smem_wr_data = gmem_rd_data;

    always_ff @(posedge clk) begin
        done <= 1'b0;
        if (rst) begin
            busy <= 1'b0;
            done_bar <= 4'd0;
            done_txbytes <= 32'd0;
            bar_q <= 4'd0; g_q <= '0; s_q <= '0; n_q <= 32'd0; cur_q <= 32'd0;
        end else begin
            if (start) begin
`ifndef SYNTHESIS
                assert (!busy)  else $fatal(1, "LOAD start while busy");
                assert (start_nbytes[3:0] == 4'h0)
                                else $fatal(1, "LOAD nbytes not 16-B multiple");
`endif
                busy  <= 1'b1;
                bar_q <= start_bar;
                g_q   <= start_gmem;
                s_q   <= start_smem;
                n_q   <= start_nbytes;
                cur_q <= 32'd0;
            end else if (busy) begin
                cur_q <= cur_q + BYTES_PER_CYCLE;
                if (cur_q + BYTES_PER_CYCLE >= n_q) begin
                    busy         <= 1'b0;
                    done         <= 1'b1;
                    done_bar     <= bar_q;
                    done_txbytes <= n_q;
                end
            end
        end
    end

endmodule

`default_nettype wire
