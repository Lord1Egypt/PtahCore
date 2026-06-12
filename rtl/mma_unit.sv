// mma_unit — operand-fetch FSM + mac_array.
//
// The cmdproc's MMA issue gives only the SMEM offsets of the A and B
// tiles, not the tiles themselves. mac_array, however, latches full
// tiles at start. This wrapper bridges the two: on `start` it streams
// both tiles out of SMEM (RD_BYTES per cycle, A and B in parallel on
// the two read ports), assembles them into the wide operand registers,
// then pulses the array and reports `done` when the array finishes.
//
// FSM: IDLE → FETCH (NCHUNK reads, 1-cycle registered SMEM latency) →
//       RUN (array does K MAC steps) → done pulse → IDLE.
//
// rd_stall (from smem_phys): the SMEM did not service this cycle's
// read addresses (a 1RW bank collision with a LOAD line write) — hold
// the fetch pointer and discard the garbage arriving next cycle. With
// rd_stall tied low the fetch is cycle-identical to the original FSM.
//
// SMEM tile layout matches the array / golden model: A is (M,K) and B
// is (N,K), both fp8 row-major, so sequential RD_BYTES chunks fill the
// operand registers in order.

`default_nettype none

module mma_unit #(
    parameter int M = 32,
    parameter int N = 32,
    parameter int K = 32,
    parameter int TMEM_SLOTS = 4,
    parameter int SLOT_W   = 2,
    parameter int SMEM_AW  = 16,
    parameter int RD_BYTES = 32
) (
    input  wire                   clk,
    input  wire                   rst,

    // spine taps, passed through to the array (CHIP_SPEC §1/§2)
    input  wire [M-1:0]           clk_row_v,
    input  wire [M-1:0]           clk_lw_v,
    input  wire [N-1:0]           clk_lb_v,
    input  wire                   clk_s,

    // MMA issue (from cmdproc)
    input  wire                   start,
    input  wire [SMEM_AW-1:0]     a_smem,
    input  wire [SMEM_AW-1:0]     b_smem,
    input  wire [SLOT_W-1:0]      slot,
    input  wire                   accum,
    input  wire                   fmt,
    output logic                  busy,
    output logic                  done,        // 1-cycle pulse

    // SMEM read ports (registered: data valid next cycle)
    output logic [SMEM_AW-1:0]    rd_a_addr,
    input  wire  [RD_BYTES*8-1:0] rd_a_data,
    output logic [SMEM_AW-1:0]    rd_b_addr,
    input  wire  [RD_BYTES*8-1:0] rd_b_data,
    input  wire                   rd_stall,

    // drain port (passthrough to the array)
    input  wire [SLOT_W-1:0]      drain_slot,
    input  wire [$clog2(M*N)-1:0] drain_idx,
    output logic [31:0]           drain_data
);

    localparam int A_BYTES = M * K;
    localparam int B_BYTES = N * K;
    localparam int NCHUNK  = (A_BYTES + RD_BYTES - 1) / RD_BYTES;  // A and B same K

    // ── operand registers + latched control ──────────────────────────
    logic [A_BYTES*8-1:0] a_reg;
    logic [B_BYTES*8-1:0] b_reg;
    logic [SMEM_AW-1:0]   a_base, b_base;
    logic [SLOT_W-1:0]    slot_q;
    logic                 accum_q, fmt_q;

    // ── FSM ──────────────────────────────────────────────────────────
    typedef enum logic [1:0] { IDLE, FETCH, RUN } state_t;
    state_t st;
    // Pipelined fetch: `f` is the next chunk to ADDRESS; (pend_v,
    // pend_idx) tracks the single in-flight read whose data arrives
    // this cycle (registered SMEM). An issue only advances f when the
    // SMEM serviced it (!rd_stall); a stalled issue leaves no in-flight
    // read, so the garbage data the colliding write produced is never
    // captured.
    logic [31:0] f;
    logic        pend_v;
    logic [31:0] pend_idx;

    // array instance
    logic        arr_start, arr_busy, arr_done;
    mac_array #(.M(M), .N(N), .K(K), .TMEM_SLOTS(TMEM_SLOTS), .SLOT_W(SLOT_W)) u_arr (
        .clk(clk), .rst(rst),
        .clk_row_v(clk_row_v), .clk_lw_v(clk_lw_v),
        .clk_lb_v(clk_lb_v), .clk_s(clk_s),
        .start(arr_start), .a_tile(a_reg), .b_tile(b_reg),
        .start_slot(slot_q), .start_accum(accum_q), .start_fmt(fmt_q),
        .busy(arr_busy), .done(arr_done),
        .drain_slot(drain_slot), .drain_idx(drain_idx), .drain_data(drain_data)
    );

    assign busy = (st != IDLE);

    // SMEM read addresses (combinational: address chunk `f`)
    assign rd_a_addr = a_base + SMEM_AW'(f * RD_BYTES);
    assign rd_b_addr = b_base + SMEM_AW'(f * RD_BYTES);

    always_ff @(posedge clk) begin
        done      <= 1'b0;
        arr_start <= 1'b0;
        if (rst) begin
            st <= IDLE; f <= 0; pend_v <= 1'b0; pend_idx <= 0;
            a_reg <= '0; b_reg <= '0;
            a_base <= '0; b_base <= '0; slot_q <= '0; accum_q <= 0; fmt_q <= 0;
        end else begin
            case (st)
                IDLE: if (start) begin
                    a_base <= a_smem; b_base <= b_smem;
                    slot_q <= slot; accum_q <= accum; fmt_q <= fmt;
                    f      <= 0;            // fetch-cycle 0 addresses chunk 0 next cy
                    pend_v <= 1'b0;
                    st     <= FETCH;
                end
                FETCH: begin
                    // capture the in-flight chunk addressed last cycle
                    if (pend_v) begin
                        a_reg[pend_idx*RD_BYTES*8 +: RD_BYTES*8] <= rd_a_data;
                        b_reg[pend_idx*RD_BYTES*8 +: RD_BYTES*8] <= rd_b_data;
                    end
                    if (pend_v && pend_idx == 32'(NCHUNK) - 32'd1) begin
                        pend_v    <= 1'b0;
                        arr_start <= 1'b1;     // all chunks captured
                        st <= RUN;
                    end else if (!rd_stall && f < 32'(NCHUNK)) begin
                        pend_v   <= 1'b1;      // this cycle's address is serviced
                        pend_idx <= f;
                        f        <= f + 32'd1;
                    end else begin
                        pend_v <= 1'b0;        // stalled: next cycle's data is garbage
                    end
                end
                RUN: if (arr_done) begin
                    done <= 1'b1;
                    st   <= IDLE;
                end
                default: st <= IDLE;
            endcase
        end
    end

endmodule

`default_nettype wire
