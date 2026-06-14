"""PtahCore — single source of truth for all design parameters.

Both the Python models and the SystemVerilog RTL derive every dimension
from this file. NEVER hardcode 32/16/etc anywhere else — read from here,
so the whole design rescales by editing one file.

SV consumption: each RTL Makefile runs
    python3 -c "from config import MMA_M; print(MMA_M)"
and passes values as Verilator -G flags / package generation.
"""

# ── MMA native tile shape ────────────────────────────────────────────
MMA_M = 32          # rows of A / D
MMA_N = 32          # cols of B / D
MMA_K = 32          # inner (reduction) dimension

# ── Operand / accumulator formats ────────────────────────────────────
FP8_FORMATS = ("e4m3", "e5m2")   # both supported per-instruction (fmt flag)
ACCUM_WIDTH = 32                 # fp32 accumulate

# ── MXFP8 microscaling (Phase 8, OCP MX spec) ────────────────────────
# K == MMA_K is exactly one MX block, so scales are per-row (A) / per-col
# (B): M E8M0 bytes for A, N for B. The shared E8M0 scale is a power of
# two, so MX is a drain-time EXPONENT ADD + saturate — no multiply, no
# change to the MAC cells. mx=0 (default) is bit-identical to plain fp8.
A_SCALE_BYTES = MMA_M            # E8M0 scales, one per A row
B_SCALE_BYTES = MMA_N            # E8M0 scales, one per B column
E8M0_BIAS = 127                  # E8M0 value = 2^(X - 127), X in [0, 254]
E8M0_NAN = 0xFF                  # X = 255 is the sole E8M0 special (NaN)

# ── Tensor memory (distributed accumulators in MAC cells) ────────────
TMEM_SLOTS = 4      # fp32 accumulator slots per MAC cell

# ── SMEM (on-chip operand scratchpad) ────────────────────────────────
SMEM_BYTES = 64 * 1024          # 64 KiB total
SMEM_BANKS = MMA_K               # one bank per K-lane, bank width = 1 byte lane
NUM_BARRIERS = 16                # mbarrier objects, 16 B each, at SMEM base
BARRIER_BYTES = 16
BARRIER_REGION = NUM_BARRIERS * BARRIER_BYTES   # reserved SMEM prefix

# ── Engine timing ────────────────────────────────────────────────────
LOAD_BYTES_PER_CYCLE = 16       # DMA bandwidth gmem→smem

# ── Command front-end ────────────────────────────────────────────────
# 64, not autogpu's 256: REPEAT is the answer to deep instruction
# streams (their documented FIFO-overflow flaw), and 256×160 b of flops
# blew up chip synthesis (yosys OOM lowering the read mux) for capacity
# v1 never needs. 64 + REPEAT ≥ 256 without it.
CMD_FIFO_DEPTH = 64             # instructions
INSTR_BITS = 64                 # fixed-width encoding
REPEAT_MAX_LEN = 32             # max body length of a REPEAT block
REPEAT_MAX_COUNT = 65535        # 16-bit repeat counter

# ── Derived sizes (do not edit) ──────────────────────────────────────
A_TILE_BYTES = MMA_M * MMA_K    # fp8 = 1 byte/elem
B_TILE_BYTES = MMA_N * MMA_K
D_TILE_FP32_BYTES = MMA_M * MMA_N * 4
D_TILE_FP8_BYTES = MMA_M * MMA_N

# ── Physical targets (ASAP7) ─────────────────────────────────────────
TARGET_CLOCK_MHZ = 250          # honest target — closed, not masked
PDK = "asap7"
