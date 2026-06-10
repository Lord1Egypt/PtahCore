// chip_top — the whole PtahCore accelerator, integrated.
//
//   instr stream → cmdproc → { barrier, load, mma_unit, store }
//                     │           │        │         │
//                     │         smem ◄──────┘ (operands)
//                     │           ▲          │ drain
//                  barriers       │ load    store → gmem
//                                 gmem(rd)         gmem(wr)
//
// External pins: instruction push (host), and a GMEM read/write port
// (driven by a behavioral DRAM in the TB; a real memory controller in
// silicon). One clock, one reset. Everything else is internal.
//
// This is the Verilator-driven integration target — a full matmul runs
// end-to-end through real RTL, bit-exact against the golden model.

`default_nettype none

module chip_top #(
    parameter int M = 32,
    parameter int N = 32,
    parameter int K = 32,
    parameter int TMEM_SLOTS  = 4,
    parameter int SLOT_W      = 2,
    parameter int NUM_BARRIERS = 16,
    parameter int SMEM_BYTES   = 65536,
    parameter int BARRIER_REGION = 256,
    parameter int SMEM_AW       = 16,
    parameter int GMEM_AW       = 32,
    parameter int RD_BYTES      = 32,
    parameter int WR_BYTES      = 16,
    parameter int IW            = 160
) (
    input  wire                clk,
    input  wire                rst,

    // host instruction push
    input  wire                push_en,
    input  wire [IW-1:0]       push_instr,
    output logic               fifo_full,
    output logic               idle,

    // GMEM read port (LOAD) — combinational 1-cycle contract
    output logic [GMEM_AW-1:0]        gmem_rd_addr,
    input  wire  [RD_BYTES*8-1:0]     gmem_rd_data,   // 32-B; LOAD uses low 16 B

    // GMEM write port (STORE)
    output logic                      gmem_wr_en,
    output logic [GMEM_AW-1:0]        gmem_wr_addr,
    output logic [31:0]               gmem_wr_data,
    output logic [2:0]                gmem_wr_nbytes
);

    // ── barrier wires ────────────────────────────────────────────────
    wire [NUM_BARRIERS-1:0] bar_phase;
    wire        bi_en, btx_en;
    wire [3:0]  bi_bar, btx_bar;
    wire [15:0] bi_count;
    wire [31:0] btx_bytes;

    // ── cmdproc → engines ────────────────────────────────────────────
    wire        ld_start;  wire [3:0] ld_bar;
    wire [31:0] ld_gmem;   wire [15:0] ld_smem;  wire [31:0] ld_nbytes;
    wire        ld_busy;

    wire        mma_start; wire [15:0] mma_a, mma_b;
    wire [1:0]  mma_slot;  wire mma_accum, mma_fmt; wire [3:0] mma_bar;
    wire        mma_busy;

    wire        st_start;  wire [3:0] st_bar;
    wire [31:0] st_gmem;   wire [1:0] st_slot; wire st_dtype;
    wire        st_busy;

    // ── engine completion → barrier arrivals ─────────────────────────
    wire        ld_done;   wire [3:0] ld_done_bar; wire [31:0] ld_done_tx;
    wire        mma_done;
    wire        st_done;   wire [3:0] st_done_bar;

    // mma_done carries no bar on its port; cmdproc latched mma_bar at
    // issue. We register it here to pair with the array's done pulse.
    logic [3:0] mma_bar_q;
    always_ff @(posedge clk) if (mma_start) mma_bar_q <= mma_bar;

    // ── SMEM ports ───────────────────────────────────────────────────
    wire                  smem_wr_en;
    wire [SMEM_AW-1:0]    smem_wr_addr;
    wire [WR_BYTES*8-1:0] smem_wr_data;
    wire [SMEM_AW-1:0]    rd_a_addr, rd_b_addr;
    wire [RD_BYTES*8-1:0] rd_a_data, rd_b_data;

    // ── drain (store ↔ mma_unit) ─────────────────────────────────────
    wire [SLOT_W-1:0]        drain_slot;
    wire [$clog2(M*N)-1:0]   drain_idx;
    wire [31:0]              drain_data;

    // ── cmdproc ──────────────────────────────────────────────────────
    cmdproc #(.NUM_BARRIERS(NUM_BARRIERS), .IW(IW)) u_cmd (
        .clk(clk), .rst(rst),
        .push_en(push_en), .push_instr(push_instr),
        .fifo_full(fifo_full), .idle(idle),
        .bar_init_en(bi_en), .bar_init_bar(bi_bar), .bar_init_count(bi_count),
        .bar_tx_en(btx_en), .bar_tx_bar(btx_bar), .bar_tx_bytes(btx_bytes),
        .bar_phase(bar_phase),
        .ld_start(ld_start), .ld_bar(ld_bar), .ld_gmem(ld_gmem),
        .ld_smem(ld_smem), .ld_nbytes(ld_nbytes), .ld_busy(ld_busy),
        .mma_start(mma_start), .mma_a(mma_a), .mma_b(mma_b), .mma_slot(mma_slot),
        .mma_accum(mma_accum), .mma_fmt(mma_fmt), .mma_bar(mma_bar), .mma_busy(mma_busy),
        .st_start(st_start), .st_bar(st_bar), .st_gmem(st_gmem),
        .st_slot(st_slot), .st_dtype(st_dtype), .st_busy(st_busy)
    );

    // ── barrier ──────────────────────────────────────────────────────
    barrier #(.NUM_BARRIERS(NUM_BARRIERS)) u_bar (
        .clk(clk), .rst(rst),
        .init_en(bi_en), .init_bar(bi_bar), .init_count(bi_count),
        .tx_en(btx_en), .tx_bar(btx_bar), .tx_bytes(btx_bytes),
        .arr0_en(ld_done),  .arr0_bar(ld_done_bar), .arr0_txdone(ld_done_tx),
        .arr1_en(mma_done), .arr1_bar(mma_bar_q),
        .arr2_en(st_done),  .arr2_bar(st_done_bar),
        .phase_q(bar_phase)
    );

    // ── SMEM ─────────────────────────────────────────────────────────
    smem #(.SMEM_BYTES(SMEM_BYTES), .BARRIER_REGION(BARRIER_REGION),
           .RD_BYTES(RD_BYTES), .WR_BYTES(WR_BYTES)) u_smem (
        .clk(clk),
        .wr_en(smem_wr_en), .wr_addr(smem_wr_addr), .wr_data(smem_wr_data),
        .rd_a_addr(rd_a_addr), .rd_a_data(rd_a_data),
        .rd_b_addr(rd_b_addr), .rd_b_data(rd_b_data)
    );

    // ── LOAD ─────────────────────────────────────────────────────────
    load #(.BYTES_PER_CYCLE(WR_BYTES), .SMEM_AW(SMEM_AW), .GMEM_AW(GMEM_AW)) u_ld (
        .clk(clk), .rst(rst),
        .start(ld_start), .start_bar(ld_bar), .start_gmem(ld_gmem),
        .start_smem(ld_smem), .start_nbytes(ld_nbytes),
        .busy(ld_busy), .done(ld_done), .done_bar(ld_done_bar),
        .done_txbytes(ld_done_tx),
        .gmem_rd_addr(gmem_rd_addr), .gmem_rd_data(gmem_rd_data[WR_BYTES*8-1:0]),
        .smem_wr_en(smem_wr_en), .smem_wr_addr(smem_wr_addr), .smem_wr_data(smem_wr_data)
    );

    // ── MMA unit (fetch + array) ─────────────────────────────────────
    mma_unit #(.M(M), .N(N), .K(K), .TMEM_SLOTS(TMEM_SLOTS), .SLOT_W(SLOT_W),
               .SMEM_AW(SMEM_AW), .RD_BYTES(RD_BYTES)) u_mma (
        .clk(clk), .rst(rst),
        .start(mma_start), .a_smem(mma_a), .b_smem(mma_b),
        .slot(mma_slot), .accum(mma_accum), .fmt(mma_fmt),
        .busy(mma_busy), .done(mma_done),
        .rd_a_addr(rd_a_addr), .rd_a_data(rd_a_data),
        .rd_b_addr(rd_b_addr), .rd_b_data(rd_b_data),
        .drain_slot(drain_slot), .drain_idx(drain_idx), .drain_data(drain_data)
    );

    // ── STORE ────────────────────────────────────────────────────────
    store #(.M(M), .N(N), .SLOT_W(SLOT_W), .GMEM_AW(GMEM_AW)) u_st (
        .clk(clk), .rst(rst),
        .start(st_start), .start_bar(st_bar), .start_gmem(st_gmem),
        .start_slot(st_slot), .start_dtype(st_dtype),
        .busy(st_busy), .done(st_done), .done_bar(st_done_bar),
        .drain_slot(drain_slot), .drain_idx(drain_idx), .drain_data(drain_data),
        .gmem_wr_en(gmem_wr_en), .gmem_wr_addr(gmem_wr_addr),
        .gmem_wr_data(gmem_wr_data), .gmem_wr_nbytes(gmem_wr_nbytes)
    );

endmodule

`default_nettype wire
