"""PtahCore ISA — instruction objects consumed by the command processor.

Design notes vs. classic Hopper/Blackwell-style ISAs:

* WAIT carries NO phase operand. The cmdproc keeps a per-barrier expected-
  phase tracker in hardware; WAIT(bar) blocks until the barrier's phase
  differs from the tracked value, then toggles the tracker. This removes
  the error-prone software phase bookkeeping entirely — and makes WAIT
  legal inside REPEAT bodies (a phase immediate would go stale across
  iterations).

* REPEAT(count, length): the next `length` instructions form a body that
  executes `count` times total. Body instructions may carry `*_step`
  strides, added once per iteration (iteration index i: addr + i*step).
  This is how a K-loop becomes 6 FIFO entries instead of 6*K.
"""

from dataclasses import dataclass


@dataclass
class BarInit:
    bar: int          # barrier index (0..NUM_BARRIERS-1)
    count: int        # expected arrivals per phase


@dataclass
class Load:
    bar: int
    gmem: int         # source byte address
    smem: int         # destination byte offset
    nbytes: int       # multiple of 16
    gstep: int = 0    # per-REPEAT-iteration stride on gmem
    sstep: int = 0    # per-REPEAT-iteration stride on smem


@dataclass
class Mma:
    bar: int
    a_smem: int       # A tile offset, (M, K) fp8 row-major
    b_smem: int       # B tile offset, (N, K) fp8 row-major
    slot: int         # TMEM accumulator slot
    accum: int = 0    # 0 = zero slot first, 1 = accumulate
    fmt: str = "e4m3"
    astep: int = 0
    bstep: int = 0
    # ── MXFP8 microscaling (Phase 8) ─────────────────────────────────
    # mx=0 is bit-identical to a plain fp8 MMA. mx=1 enables per-block
    # E8M0 scaling: sa_smem points at M E8M0 bytes (one scale per A row),
    # sb_smem at N E8M0 bytes (one per B col). The scale is applied to the
    # slot's accumulator at DRAIN — a pure exponent add (golden/mxfp8.py).
    mx: int = 0
    sa_smem: int = 0  # SMEM offset of the M E8M0 row scales
    sb_smem: int = 0  # SMEM offset of the N E8M0 col scales
    sastep: int = 0   # per-REPEAT-iteration stride on sa_smem
    sbstep: int = 0   # per-REPEAT-iteration stride on sb_smem
    # ── 2:4 structured sparsity (Phase 9) ────────────────────────────
    # sparse=0 is the dense MMA. sparse=1: A is 2:4-compressed — a_smem
    # holds the M×(K/2) kept fp8 values, meta_smem the M×(K/4) metadata
    # bytes. The array runs K/2 steps (the two zero lanes per group are
    # skipped → ~2× throughput); the result equals the dense matmul of the
    # decompressed A (golden/sparse24.py).
    sparse: int = 0
    meta_smem: int = 0   # SMEM offset of the M×(K/4) 2:4 metadata bytes
    mstep: int = 0       # per-REPEAT-iteration stride on meta_smem


@dataclass
class Store:
    bar: int
    gmem: int         # destination byte address
    slot: int         # TMEM slot to drain
    dtype: int = 0    # 0 = fp32 out, 1 = fp8 e4m3 out
    gstep: int = 0


@dataclass
class Wait:
    bar: int          # auto-phase: hardware tracks expected phase


@dataclass
class Repeat:
    count: int        # total iterations (count >= 1)
    length: int       # number of following instructions in the body
