// cmdproc — instruction front-end. Twin: pymodel/cmdproc.py.
//
// Pops one 160-bit instruction per cycle from the FIFO and dispatches
// it to the matching engine, fire-and-forget. Stalls only on (a) WAIT
// until the barrier flips, (b) a busy target engine. Implements the two
// PtahCore control improvements:
//   * auto-phase WAIT — a per-barrier expected-phase tracker means WAIT
//     carries no phase operand and is correct inside REPEAT bodies.
//   * REPEAT — captures the next `length` instructions and replays them
//     `count` times, adding per-iteration address strides.
//
// Instruction word (160 bits, little-field):
//   [3:0]     op     0=BARINIT 1=LOAD 2=MMA 3=STORE 4=WAIT 5=REPEAT
//   [7:4]     bar
//   [23:8]    a16    LOAD smem / MMA a_smem / BARINIT count / REPEAT count
//   [39:24]   b16    MMA b_smem / REPEAT length
//   [71:40]   g32    LOAD/STORE gmem
//   [103:72]  n32    LOAD nbytes
//   [105:104] slot   MMA/STORE
//   [106]     accdt  MMA accum / STORE dtype
//   [107]     fmt    MMA
//   [123:108] s0     step0 (LOAD gstep / MMA astep / STORE gstep)
//   [139:124] s1     step1 (LOAD sstep / MMA bstep)

`default_nettype none

module cmdproc #(
    parameter int NUM_BARRIERS = 16,
    parameter int FIFO_DEPTH   = 256,
    parameter int MAX_BODY     = 32,
    parameter int IW           = 160
) (
    input  wire            clk,
    input  wire            rst,

    input  wire            push_en,
    input  wire [IW-1:0]   push_instr,
    output logic           fifo_full,
    output logic           idle,

    output logic           bar_init_en,
    output logic [3:0]     bar_init_bar,
    output logic [15:0]    bar_init_count,
    output logic           bar_tx_en,
    output logic [3:0]     bar_tx_bar,
    output logic [31:0]    bar_tx_bytes,
    input  wire [NUM_BARRIERS-1:0] bar_phase,

    output logic           ld_start,
    output logic [3:0]     ld_bar,
    output logic [31:0]    ld_gmem,
    output logic [15:0]    ld_smem,
    output logic [31:0]    ld_nbytes,
    input  wire            ld_busy,

    output logic           mma_start,
    output logic [15:0]    mma_a,
    output logic [15:0]    mma_b,
    output logic [1:0]     mma_slot,
    output logic           mma_accum,
    output logic           mma_fmt,
    output logic [3:0]     mma_bar,
    input  wire            mma_busy,

    output logic           st_start,
    output logic [3:0]     st_bar,
    output logic [31:0]    st_gmem,
    output logic [1:0]     st_slot,
    output logic           st_dtype,
    input  wire            st_busy
);

    localparam int AW = $clog2(FIFO_DEPTH);
    localparam int BW = $clog2(MAX_BODY);
    localparam [3:0] OP_BARINIT=0, OP_LOAD=1, OP_MMA=2, OP_STORE=3,
                     OP_WAIT=4, OP_REPEAT=5;

    // ── FIFO ─────────────────────────────────────────────────────────
    logic [IW-1:0] fifo [FIFO_DEPTH];
    logic [AW:0]   head, tail, count;
    wire fifo_empty = (count == 0);
    assign fifo_full = (count == (AW+1)'(FIFO_DEPTH));

    // ── REPEAT state ─────────────────────────────────────────────────
    logic [IW-1:0] body [MAX_BODY];
    logic [BW:0]   cap_left, body_len, body_pos;
    logic          replaying;
    logic [15:0]   rep_count, rep_iter;

    // ── WAIT + phase trackers ────────────────────────────────────────
    logic        waiting;
    logic [3:0]  wait_bar;
    logic [NUM_BARRIERS-1:0] tracker;

    // engine-issue guards: a freshly issued engine's `busy` only rises
    // one cycle later (registered start → registered busy). Without this
    // the front-end would issue a second op into the same engine in that
    // window. We treat an engine as busy the cycle after we start it.
    logic ld_iss_d, mma_iss_d, st_iss_d;
    wire  ld_busy_e  = ld_busy  || ld_iss_d;
    wire  mma_busy_e = mma_busy || mma_iss_d;
    wire  st_busy_e  = st_busy  || st_iss_d;

    assign idle = fifo_empty && !waiting && !replaying && (cap_left == 0);

    // ── current instruction: replay body, else FIFO head ─────────────
    logic [IW-1:0] cur;
    logic          cur_valid;
    always_comb begin
        if (replaying) begin
            cur = body[body_pos[BW-1:0]];
            cur_valid = 1'b1;
        end else if (!fifo_empty && cap_left == 0) begin
            cur = fifo[head[AW-1:0]];
            cur_valid = 1'b1;
        end else begin
            cur = '0;
            cur_valid = 1'b0;
        end
    end

    wire [3:0]  op    = cur[3:0];
    wire [3:0]  bar   = cur[7:4];
    wire [15:0] a16   = cur[23:8];
    wire [15:0] b16   = cur[39:24];
    wire [31:0] g32   = cur[71:40];
    wire [31:0] n32   = cur[103:72];
    wire [1:0]  slot  = cur[105:104];
    wire        accdt = cur[106];
    wire        fmt   = cur[107];
    wire [15:0] s0    = cur[123:108];
    wire [15:0] s1    = cur[139:124];

    wire [15:0] it = replaying ? rep_iter : 16'd0;
    wire [31:0] eff_gmem = g32 + 32'(it) * 32'(s0);
    wire [15:0] eff_smem = a16 + it * s1;     // LOAD dst stride
    wire [15:0] eff_a    = a16 + it * s0;     // MMA A stride
    wire [15:0] eff_b    = b16 + it * s1;     // MMA B stride

    // ── combinational decode: does this instr issue, and does it pop? ─
    // `issue` = the instruction is consumed this cycle (engine free etc).
    // `pop`   = a FIFO entry is removed (consumed but NOT during replay,
    //            and capture/REPEAT consume too).
    logic issue, pop, adv_replay;
    always_comb begin
        issue = 1'b0;
        case (op)
            OP_BARINIT: issue = 1'b1;
            OP_LOAD:    issue = !ld_busy_e;
            OP_MMA:     issue = !mma_busy_e;
            OP_STORE:   issue = !st_busy_e;
            OP_WAIT:    issue = 1'b1;
            OP_REPEAT:  issue = 1'b0;   // handled specially
            default:    issue = 1'b1;
        endcase
        // pop a FIFO entry only when consuming from the FIFO (not replay)
        pop        = cur_valid && issue && !replaying;
        adv_replay = cur_valid && issue && replaying;
    end

    always_ff @(posedge clk) begin
        bar_init_en <= 1'b0;
        bar_tx_en   <= 1'b0;
        ld_start    <= 1'b0;
        mma_start   <= 1'b0;
        st_start    <= 1'b0;
        // guards mirror the start strobes we set this cycle (default clear)
        ld_iss_d    <= 1'b0;
        mma_iss_d   <= 1'b0;
        st_iss_d    <= 1'b0;

        if (rst) begin
            head <= 0; tail <= 0; count <= 0;
            cap_left <= 0; body_len <= 0; body_pos <= 0;
            replaying <= 1'b0; rep_count <= 0; rep_iter <= 0;
            waiting <= 1'b0; wait_bar <= 0; tracker <= '0;
            ld_iss_d <= 1'b0; mma_iss_d <= 1'b0; st_iss_d <= 1'b0;
        end else begin
            logic pushed, popped;
            logic [BW:0] body_widx;
            pushed = push_en && !fifo_full;
            popped = 1'b0;
            body_widx = body_len - cap_left;   // capture write index

            if (pushed) begin
                fifo[tail[AW-1:0]] <= push_instr;
                tail <= tail + 1'b1;
            end

            if (waiting) begin
                if (bar_phase[wait_bar] != tracker[wait_bar]) begin
                    tracker[wait_bar] <= ~tracker[wait_bar];
                    waiting <= 1'b0;
                end
            end else if (cap_left != 0) begin
                // capture REPEAT body, one FIFO entry per cycle
                if (!fifo_empty) begin
                    body[body_widx[BW-1:0]] <= fifo[head[AW-1:0]];
                    head   <= head + 1'b1;
                    popped = 1'b1;
                    cap_left <= cap_left - 1'b1;
                    if (cap_left == 1) begin
                        replaying <= 1'b1;
                        rep_iter  <= 0;
                        body_pos  <= 0;
                    end
                end
            end else if (!replaying && cur_valid && op == OP_REPEAT) begin
                // start a REPEAT block
                rep_count <= a16;
                body_len  <= b16[BW:0];
                cap_left  <= b16[BW:0];
                head   <= head + 1'b1;     // consume the REPEAT word
                popped = 1'b1;
            end else if (cur_valid && issue) begin
                // dispatch
                case (op)
                    OP_BARINIT: begin
                        bar_init_en <= 1'b1; bar_init_bar <= bar;
                        bar_init_count <= a16; tracker[bar] <= 1'b0;
                    end
                    OP_LOAD: begin
                        ld_start <= 1'b1; ld_iss_d <= 1'b1; ld_bar <= bar;
                        ld_gmem <= eff_gmem; ld_smem <= eff_smem;
                        ld_nbytes <= n32;
                        bar_tx_en <= 1'b1; bar_tx_bar <= bar; bar_tx_bytes <= n32;
                    end
                    OP_MMA: begin
                        mma_start <= 1'b1; mma_iss_d <= 1'b1;
                        mma_a <= eff_a; mma_b <= eff_b;
                        mma_slot <= slot; mma_accum <= accdt; mma_fmt <= fmt;
                        mma_bar <= bar;
                    end
                    OP_STORE: begin
                        st_start <= 1'b1; st_iss_d <= 1'b1; st_bar <= bar;
                        st_gmem <= eff_gmem; st_slot <= slot; st_dtype <= accdt;
                    end
                    OP_WAIT: begin
                        if (bar_phase[bar] != tracker[bar])
                            tracker[bar] <= ~tracker[bar];
                        else begin
                            waiting <= 1'b1; wait_bar <= bar;
                        end
                    end
                    default: ;
                endcase

                if (replaying) begin
                    if (body_pos == body_len - 1) begin
                        body_pos <= 0;
                        if (rep_iter == rep_count - 1) replaying <= 1'b0;
                        else rep_iter <= rep_iter + 1'b1;
                    end else begin
                        body_pos <= body_pos + 1'b1;
                    end
                end else begin
                    head <= head + 1'b1;   // pop FIFO
                    popped = 1'b1;
                end
            end

            // net FIFO count update
            count <= count + (pushed ? (AW+1)'(1) : '0)
                           - (popped ? (AW+1)'(1) : '0);
        end
    end

endmodule

`default_nettype wire
