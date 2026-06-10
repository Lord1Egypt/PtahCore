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

# ── Tensor memory (distributed accumulators in MAC cells) ────────────
TMEM_SLOTS = 4      # fp32 accumulator slots per MAC cell

# ── SMEM (on-chip operand scratchpad) ────────────────────────────────
SMEM_BYTES = 64 * 1024          # 64 KiB total
SMEM_BANKS = MMA_K               # one bank per K-lane, bank width = 1 byte lane
NUM_BARRIERS = 16                # mbarrier objects, 16 B each, at SMEM base
BARRIER_BYTES = 16
BARRIER_REGION = NUM_BARRIERS * BARRIER_BYTES   # reserved SMEM prefix

# ── Command front-end ────────────────────────────────────────────────
CMD_FIFO_DEPTH = 256            # instructions
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
