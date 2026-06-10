// barrier — mbarrier file. Pymodel twin: pymodel/barrier.py.
//
// NUM_BARRIERS entries of {pending, expected, tx, phase}. Flip rule
// after every state-changing op: pending==0 && tx==0 → phase ^= 1,
// pending = expected.
//
// Port plan (one per producer, all may fire in the same cycle):
//   init    — from cmdproc (BAR.INIT)
//   add_tx  — from cmdproc at LOAD issue (atomic with issue)
//   arrive0 — LOAD completion   (carries tx_done)
//   arrive1 — MMA completion
//   arrive2 — STORE completion
//
// Same-cycle ops are applied in the fixed order init → add_tx →
// arrive0 → arrive1 → arrive2, each followed by the flip rule —
// matching the pymodel's sequential method-call semantics.
//
// phase_q exposes all phases combinationally for the cmdproc's WAIT.

`default_nettype none

module barrier #(
    parameter int NUM_BARRIERS = 16,
    parameter int BAR_W        = 4
) (
    input  wire                clk,
    input  wire                rst,

    input  wire                init_en,
    input  wire [BAR_W-1:0]    init_bar,
    input  wire [15:0]         init_count,

    input  wire                tx_en,
    input  wire [BAR_W-1:0]    tx_bar,
    input  wire [31:0]         tx_bytes,

    input  wire                arr0_en,
    input  wire [BAR_W-1:0]    arr0_bar,
    input  wire [31:0]         arr0_txdone,

    input  wire                arr1_en,
    input  wire [BAR_W-1:0]    arr1_bar,

    input  wire                arr2_en,
    input  wire [BAR_W-1:0]    arr2_bar,

    output logic [NUM_BARRIERS-1:0] phase_q
);

    logic [15:0] pending  [NUM_BARRIERS];
    logic [15:0] expected [NUM_BARRIERS];
    logic [31:0] tx       [NUM_BARRIERS];
    logic [NUM_BARRIERS-1:0] phase;

    assign phase_q = phase;

    // next-state working copies (blocking assigns inside one comb body)
    logic [15:0] n_pending  [NUM_BARRIERS];
    logic [15:0] n_expected [NUM_BARRIERS];
    logic [31:0] n_tx       [NUM_BARRIERS];
    logic [NUM_BARRIERS-1:0] n_phase;

    // flip rule, applied inline after every arrival (Verilator flags
    // module-scope writes from functions as MULTIDRIVEN)
`define FLIP_IF_READY(b) \
        if (n_pending[b] == 16'd0 && n_tx[b] == 32'd0) begin \
            n_phase[b]   = ~n_phase[b]; \
            n_pending[b] = n_expected[b]; \
        end

    always_comb begin
        for (int b = 0; b < NUM_BARRIERS; b++) begin
            n_pending[b]  = pending[b];
            n_expected[b] = expected[b];
            n_tx[b]       = tx[b];
        end
        n_phase = phase;

        if (init_en) begin
            n_pending[init_bar]  = init_count;
            n_expected[init_bar] = init_count;
            n_tx[init_bar]       = 32'd0;
            n_phase[init_bar]    = 1'b0;
        end

        if (tx_en)
            n_tx[tx_bar] = n_tx[tx_bar] + tx_bytes;

        if (arr0_en) begin
            n_tx[arr0_bar]      = n_tx[arr0_bar] - arr0_txdone;
            n_pending[arr0_bar] = n_pending[arr0_bar] - 16'd1;
            `FLIP_IF_READY(arr0_bar)
        end
        if (arr1_en) begin
            n_pending[arr1_bar] = n_pending[arr1_bar] - 16'd1;
            `FLIP_IF_READY(arr1_bar)
        end
        if (arr2_en) begin
            n_pending[arr2_bar] = n_pending[arr2_bar] - 16'd1;
            `FLIP_IF_READY(arr2_bar)
        end
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            for (int b = 0; b < NUM_BARRIERS; b++) begin
                pending[b]  <= 16'd0;
                expected[b] <= 16'd0;
                tx[b]       <= 32'd0;
            end
            phase <= '0;
        end else begin
            for (int b = 0; b < NUM_BARRIERS; b++) begin
                pending[b]  <= n_pending[b];
                expected[b] <= n_expected[b];
                tx[b]       <= n_tx[b];
            end
            phase <= n_phase;
        end
    end

endmodule

`default_nettype wire
