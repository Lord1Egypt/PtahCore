"""mac_array — the 32×32 broadcast MAC grid with distributed TMEM.

Each (i, j) cell holds TMEM_SLOTS fp32 accumulators. An MMA broadcasts
one column of A (M values) and one column of B (N values) per cycle for
K cycles; cell (i, j) computes acc[slot] += fp32(A[i,k]) * fp32(B[j,k]).

INPUTS (sampled at tick start)
    start(a_tile, b_tile, slot, accum, fmt) — a/b are (M,K)/(N,K) uint8
    drain_read(slot, idx) — STORE-side: row-major element idx of slot

OUTPUTS (valid after tick)
    busy : bool
    done : bool (1-cycle pulse when the K-loop finishes)

INTERNAL STATE
    tmem : float32[M, N, TMEM_SLOTS]
    k    : current K-step; a/b operand latches

BEHAVIOR (per tick)
    1. If running: consume K-step k — all M×N cells MAC in parallel
       (one cycle per K-step, like the systolic broadcast in RTL).
    2. k == K: assert done, clear busy.
    3. accum=0 zeroes the slot before the first MAC step.

INVARIANTS
    - A slot being drained must not be MMA-target (asserted in sim).
    - Accumulation order is k = 0..K-1, matching golden/matmul_reference.
"""

import numpy as np

import config
from golden.fp8 import decode_array
from golden.mxfp8 import E8M0_BIAS, scale_value


class MacArray:
    def __init__(self):
        m, n = config.MMA_M, config.MMA_N
        self.tmem = np.zeros((m, n, config.TMEM_SLOTS), dtype=np.float32)
        self.busy = False
        self.done = False
        self._a = None      # (M, K) float32, decoded at start (operand latch)
        self._b = None      # (N, K) float32
        self._slot = 0
        self._k = 0
        self._nsteps = config.MMA_K   # K dense, K/2 sparse (set at start)
        self._sparse = 0
        self._a_meta = None
        # ── per-slot MXFP8 scale state (Phase 8) ─────────────────────
        # The scale belongs to the MMA that wrote the slot and must persist
        # until that slot is drained (STORE is async). Applied at drain,
        # exactly like the RTL: mma_unit holds these regfiles, store reads
        # the matched element's scale at write-back.
        self._mx = [0] * config.TMEM_SLOTS               # per-slot enable
        self._sa = [np.full(m, E8M0_BIAS, np.uint8)      # per-slot M row scales
                    for _ in range(config.TMEM_SLOTS)]
        self._sb = [np.full(n, E8M0_BIAS, np.uint8)      # per-slot N col scales
                    for _ in range(config.TMEM_SLOTS)]

    def start(self, a_tile: np.ndarray, b_tile: np.ndarray, slot: int,
              accum: int, fmt: str, mx: int = 0,
              scale_a: np.ndarray | None = None,
              scale_b: np.ndarray | None = None,
              sparse: int = 0, a_meta: np.ndarray | None = None):
        assert not self.busy, "MMA issued while array busy"
        # 2:4 sparse: a_tile is the compressed M×(K/2) kept values; the
        # array runs K/2 steps, gathering B per-row by the metadata. Dense:
        # the full M×K tile, K steps. Both accumulate in ascending k order,
        # so the sparse sum equals the dense (zero lanes are exact no-ops).
        self._sparse = int(sparse)
        self._a = decode_array(a_tile, fmt)
        self._b = decode_array(b_tile, fmt)
        self._slot = slot
        self._k = 0
        if sparse:
            assert a_meta is not None
            self._a_meta = np.asarray(a_meta, np.uint8)
            self._nsteps = config.MMA_K // 2
        else:
            self._nsteps = config.MMA_K
        if not accum:
            self.tmem[:, :, slot] = np.float32(0)
        # latch the slot's MX scale state (mx=0 clears it → plain drain)
        self._mx[slot] = int(mx)
        if mx:
            assert scale_a is not None and scale_b is not None
            self._sa[slot] = np.asarray(scale_a, np.uint8).copy()
            self._sb[slot] = np.asarray(scale_b, np.uint8).copy()
        self.busy = True

    def tick(self):
        self.done = False
        if not self.busy:
            return
        s = self._k
        if self._sparse:
            # step s → group g, kept-slot (0/1); each row selects its own
            # B column from the group via metadata (per-row gather).
            g, which = s // 2, s % 2
            pos = (self._a_meta[:, g] >> (2 * which)) & 0b11   # (M,)
            actual_k = 4 * g + pos                             # (M,)
            bsel = self._b[:, actual_k].T                      # (M, N)
            prod = (self._a[:, s:s + 1] * bsel).astype(np.float32)
        else:
            # one K-step per cycle: rank-1 update in fp32
            prod = (self._a[:, s:s + 1] * self._b[:, s:s + 1].T).astype(np.float32)
        self.tmem[:, :, self._slot] += prod
        self._k += 1
        if self._k == self._nsteps:
            self.busy = False
            self.done = True

    def drain_read(self, slot: int, idx: int) -> np.float32:
        """Row-major element idx of an accumulator slot (STORE side).

        If the slot was written by an MX MMA, the per-element E8M0 scale is
        applied here — the drain-time exponent add (bit-exact, golden twin).
        mx=0 returns the raw accumulator, identical to the pre-Phase-8 path.
        """
        m, n = config.MMA_M, config.MMA_N
        i, j = idx // n, idx % n
        val = self.tmem[i, j, slot]
        if self._mx[slot]:
            return scale_value(val, int(self._sa[slot][i]), int(self._sb[slot][j]))
        return val
