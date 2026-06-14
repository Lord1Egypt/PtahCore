// cmdproc_tb_top — cmdproc + real barrier, with engine ports exposed so
// the cocotb TB can act as the three engines (assert busy, pulse the
// completion arrivals into the barrier). Lets us verify decode, REPEAT
// strides, auto-phase WAIT, and engine-busy stalls end to end.

`default_nettype none

module cmdproc_tb_top #(
    parameter int NUM_BARRIERS = 16,
    parameter int IW = 160
) (
    input  wire            clk,
    input  wire            rst,

    input  wire            push_en,
    input  wire [IW-1:0]   push_instr,
    output logic           fifo_full,
    output logic           idle,

    // engine busy inputs (driven by TB)
    input  wire            ld_busy,
    input  wire            mma_busy,
    input  wire            st_busy,

    // completion arrivals (driven by TB to model engine done)
    input  wire            arr0_en, input wire [3:0] arr0_bar, input wire [31:0] arr0_txdone,
    input  wire            arr1_en, input wire [3:0] arr1_bar,
    input  wire            arr2_en, input wire [3:0] arr2_bar,

    // observable engine-start strobes + operands
    output logic           ld_start,
    output logic [3:0]     ld_bar,
    output logic [31:0]    ld_gmem,
    output logic [15:0]    ld_smem,
    output logic [31:0]    ld_nbytes,

    output logic           mma_start,
    output logic [15:0]    mma_a,
    output logic [15:0]    mma_b,
    output logic [1:0]     mma_slot,
    output logic           mma_accum,
    output logic           mma_fmt,
    output logic [3:0]     mma_bar,
    output logic           mma_mx,
    output logic [15:0]    mma_sa,
    output logic [15:0]    mma_sb,

    output logic           st_start,
    output logic [3:0]     st_bar,
    output logic [31:0]    st_gmem,
    output logic [1:0]     st_slot,
    output logic           st_dtype
);

    wire [NUM_BARRIERS-1:0] bar_phase;
    wire        bar_init_en, bar_tx_en;
    wire [3:0]  bar_init_bar, bar_tx_bar;
    wire [15:0] bar_init_count;
    wire [31:0] bar_tx_bytes;

    cmdproc #(.NUM_BARRIERS(NUM_BARRIERS), .IW(IW)) u_cmd (
        .clk(clk), .rst(rst),
        .push_en(push_en), .push_instr(push_instr),
        .fifo_full(fifo_full), .idle(idle),
        .bar_init_en(bar_init_en), .bar_init_bar(bar_init_bar),
        .bar_init_count(bar_init_count),
        .bar_tx_en(bar_tx_en), .bar_tx_bar(bar_tx_bar), .bar_tx_bytes(bar_tx_bytes),
        .bar_phase(bar_phase),
        .ld_start(ld_start), .ld_bar(ld_bar), .ld_gmem(ld_gmem),
        .ld_smem(ld_smem), .ld_nbytes(ld_nbytes), .ld_busy(ld_busy),
        .mma_start(mma_start), .mma_a(mma_a), .mma_b(mma_b), .mma_slot(mma_slot),
        .mma_accum(mma_accum), .mma_fmt(mma_fmt), .mma_bar(mma_bar),
        .mma_mx(mma_mx), .mma_sa(mma_sa), .mma_sb(mma_sb), .mma_busy(mma_busy),
        .st_start(st_start), .st_bar(st_bar), .st_gmem(st_gmem),
        .st_slot(st_slot), .st_dtype(st_dtype), .st_busy(st_busy)
    );

    barrier #(.NUM_BARRIERS(NUM_BARRIERS)) u_bar (
        .clk(clk), .rst(rst),
        .init_en(bar_init_en), .init_bar(bar_init_bar), .init_count(bar_init_count),
        .tx_en(bar_tx_en), .tx_bar(bar_tx_bar), .tx_bytes(bar_tx_bytes),
        .arr0_en(arr0_en), .arr0_bar(arr0_bar), .arr0_txdone(arr0_txdone),
        .arr1_en(arr1_en), .arr1_bar(arr1_bar),
        .arr2_en(arr2_en), .arr2_bar(arr2_bar),
        .phase_q(bar_phase)
    );

endmodule

`default_nettype wire
