// smem_phys — the physical SMEM: banked 1RW SRAM macros behind the
// behavioral smem's exact port contract, plus a read stall.
//
// Geometry (v1): 64 KiB logical = 2048 lines x 32 B.
//   - 2 COPIES (one per read port) — duplication buys the second read
//     port out of 1RW macros; every line write broadcasts to both
//     copies. 2x the silicon, honestly accounted.
//   - 8 banks/copy of fakeram7_256x256 (256 lines x 256 b, 1RW);
//     bank = line[10:8], i.e. contiguous 8 KiB regions, so double-
//     buffered tiles land in different banks and LOAD/MMA overlap
//     rarely collides.
//   - LOAD's 16-B beats are COALESCED: the low half-line is registered
//     and the high-half beat writes the full 32-B line (fakeram has no
//     write mask). Contract (asserted): the LOAD smem destination is
//     32-B aligned and the length a multiple of 32 — a tile is 1024 B,
//     already compliant. The barrier-region floor and 16-B alignment
//     asserts carry over from the behavioral smem unchanged.
//   - 1RW collision (a line write entering the same bank a read port
//     addresses) STALLS the reader: rd_stall high means "this cycle's
//     read addresses were not serviced; the data arriving next cycle
//     is garbage — reissue the address". Writes never stall (LOAD's
//     gmem stream has no backpressure; a read retry is one cycle).
//
// Reads must be 32-B aligned (asserted): mma_unit reads base + k*32,
// so aligning the MMA instruction's tile base aligns every access.
//
// Pymodel twin: pymodel/smem.py models the BEHAVIOR (reads return
// written bytes); stall timing is RTL-internal and absorbed by the
// barrier protocol exactly like engine busy cycles.

`default_nettype none

module smem_phys #(
    parameter int SMEM_BYTES     = 65536,
    parameter int BARRIER_REGION = 256,
    parameter int RD_BYTES       = 32,
    parameter int WR_BYTES       = 16
) (
    input  wire                           clk,
    input  wire                           rst,

    input  wire                           wr_en,
    input  wire  [$clog2(SMEM_BYTES)-1:0] wr_addr,     // 16-B aligned
    input  wire  [WR_BYTES*8-1:0]         wr_data,

    input  wire  [$clog2(SMEM_BYTES)-1:0] rd_a_addr,   // 32-B aligned
    output logic [RD_BYTES*8-1:0]         rd_a_data,   // valid next cycle
    input  wire  [$clog2(SMEM_BYTES)-1:0] rd_b_addr,
    output logic [RD_BYTES*8-1:0]         rd_b_data,
    output logic                          rd_stall
);

    localparam int AW     = $clog2(SMEM_BYTES);    // 16
    localparam int LINE_B = RD_BYTES;              // 32
    localparam int LSH    = $clog2(LINE_B);        // 5
    localparam int NLINES = SMEM_BYTES / LINE_B;   // 2048
    localparam int LAW    = $clog2(NLINES);        // 11
    localparam int NBANKS = 8;
    localparam int BSEL   = $clog2(NBANKS);        // 3
    localparam int BAW    = LAW - BSEL;            // 8

    // ── line / bank decode ───────────────────────────────────────────
    wire [LAW-1:0]  wline = wr_addr[AW-1:LSH];
    wire [LAW-1:0]  aline = rd_a_addr[AW-1:LSH];
    wire [LAW-1:0]  bline = rd_b_addr[AW-1:LSH];
    wire [BSEL-1:0] wbank = wline[LAW-1:BAW];
    wire [BSEL-1:0] abank = aline[LAW-1:BAW];
    wire [BSEL-1:0] bbank = bline[LAW-1:BAW];

    // ── write coalescer: 16-B beats → 32-B line writes ───────────────
    logic                  pend_v;
    logic [LAW-1:0]        pend_line;
    logic [WR_BYTES*8-1:0] pend_lo;

    wire hi_half     = wr_addr[LSH-1];
    wire line_wr_en  = wr_en && hi_half;
    wire [RD_BYTES*8-1:0] line_wr_data = {wr_data, pend_lo};

    always_ff @(posedge clk) begin
        if (rst) begin
            pend_v <= 1'b0;
        end else if (wr_en) begin
`ifndef SYNTHESIS
            assert (wr_addr[LSH-2:0] == '0)
                else $fatal(1, "smem_phys write not 16-B aligned: %0d", wr_addr);
            assert (32'(wr_addr) >= BARRIER_REGION)
                else $fatal(1, "smem_phys write into barrier region: %0d", wr_addr);
            if (!hi_half)
                assert (!pend_v)
                    else $fatal(1, "smem_phys: two low half-line beats (LOAD dest not 32-B aligned?)");
            else
                assert (pend_v && pend_line == wline)
                    else $fatal(1, "smem_phys: high half-line beat without its pair");
`endif
            if (!hi_half) begin
                pend_v    <= 1'b1;
                pend_line <= wline;
                pend_lo   <= wr_data;
            end else begin
                pend_v <= 1'b0;
            end
        end
    end

    // ── read-alignment contract ──────────────────────────────────────
`ifndef SYNTHESIS
    always_ff @(posedge clk) begin
        assert (rd_a_addr[LSH-1:0] == '0)
            else $fatal(1, "smem_phys read A not 32-B aligned: %0d", rd_a_addr);
        assert (rd_b_addr[LSH-1:0] == '0)
            else $fatal(1, "smem_phys read B not 32-B aligned: %0d", rd_b_addr);
    end
`endif

    // ── stall: a line write owns its bank in BOTH copies this cycle ──
    assign rd_stall = line_wr_en && ((wbank == abank) || (wbank == bbank));

    // ── banks: 2 copies x 8 of fakeram7_256x256, write priority ──────
    wire [NBANKS-1:0][RD_BYTES*8-1:0] dout_a;
    wire [NBANKS-1:0][RD_BYTES*8-1:0] dout_b;
    logic [BSEL-1:0] abank_q, bbank_q;
    always_ff @(posedge clk) begin
        abank_q <= abank;
        bbank_q <= bbank;
    end

    generate
        for (genvar g = 0; g < NBANKS; g++) begin : bank
            wire we_g = line_wr_en && (wbank == BSEL'(g));
            fakeram7_256x256 u_copy_a (
                .rd_out (dout_a[g]),
                .addr_in(we_g ? wline[BAW-1:0] : aline[BAW-1:0]),
                .we_in  (we_g),
                .wd_in  (line_wr_data),
                .clk    (clk),
                .ce_in  (we_g || (abank == BSEL'(g)))
            );
            fakeram7_256x256 u_copy_b (
                .rd_out (dout_b[g]),
                .addr_in(we_g ? wline[BAW-1:0] : bline[BAW-1:0]),
                .we_in  (we_g),
                .wd_in  (line_wr_data),
                .clk    (clk),
                .ce_in  (we_g || (bbank == BSEL'(g)))
            );
        end
    endgenerate

    assign rd_a_data = dout_a[abank_q];
    assign rd_b_data = dout_b[bbank_q];

endmodule

`default_nettype wire
