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

    def start(self, a_tile: np.ndarray, b_tile: np.ndarray, slot: int,
              accum: int, fmt: str):
        assert not self.busy, "MMA issued while array busy"
        self._a = decode_array(a_tile, fmt)
        self._b = decode_array(b_tile, fmt)
        self._slot = slot
        self._k = 0
        if not accum:
            self.tmem[:, :, slot] = np.float32(0)
        self.busy = True

    def tick(self):
        self.done = False
        if not self.busy:
            return
        k = self._k
        # one K-step per cycle: rank-1 update in fp32
        prod = (self._a[:, k:k + 1] * self._b[:, k:k + 1].T).astype(np.float32)
        self.tmem[:, :, self._slot] += prod
        self._k += 1
        if self._k == config.MMA_K:
            self.busy = False
            self.done = True

    def drain_read(self, slot: int, idx: int) -> np.float32:
        """Row-major element idx of an accumulator slot (STORE side)."""
        m, n = config.MMA_M, config.MMA_N
        return self.tmem[idx // n, idx % n, slot]
