"""store — ASYNC drain engine, TMEM slot → gmem.

PtahCore improvement over autogpu: STORE signals a barrier on completion
instead of stalling the front-end, so the next kernel's LOADs overlap
the epilogue.

INPUTS
    start(bar, gmem, slot, dtype) — issue and return immediately

OUTPUTS (valid after tick)
    busy : bool

INTERNAL STATE
    idx — elements drained so far (row-major)

BEHAVIOR (per tick)
    1. At each drain-row change (every MMA_N elements, and at burst
       start) spend ONE settle tick without draining — the RTL twin's
       row-change bubble that lets the grid's southbound drain chain
       settle (ARRAY_SPEC §3). MMA_M extra ticks per burst.
    2. Otherwise drain ONE fp32 element from the array's slot.
       dtype=0: write 4-byte fp32 little-endian. dtype=1: convert to
       fp8 e4m3 (golden encode — saturating, nearest-even), write 1 byte.
    3. After M*N elements: bar.arrive() — pending -= 1, flip rule.

INVARIANTS
    - The drained slot must not be the target of a concurrent MMA
      (enforced by the sim harness assertion).
"""

import struct

import config
from golden.fp8 import encode


class StoreEngine:
    def __init__(self, gmem, array, barriers):
        self.gmem = gmem
        self.array = array
        self.bars = barriers
        self.busy = False
        self._bar = 0
        self._g = 0
        self._slot = 0
        self._dtype = 0
        self._idx = 0
        self._settled = False

    def start(self, bar: int, gmem: int, slot: int, dtype: int):
        assert not self.busy, "STORE issued while engine busy"
        self._bar, self._g, self._slot, self._dtype = bar, gmem, slot, dtype
        self._idx = 0
        self._settled = False
        self.busy = True

    @property
    def draining_slot(self):
        return self._slot if self.busy else None

    def tick(self):
        if not self.busy:
            return
        if self._idx % config.MMA_N == 0 and not self._settled:
            self._settled = True          # row-change settle bubble
            return
        val = float(self.array.drain_read(self._slot, self._idx))
        if self._dtype == 0:
            self.gmem.write(self._g + self._idx * 4, struct.pack("<f", val))
        else:
            self.gmem.write(self._g + self._idx, bytes([encode(val, "e4m3")]))
        self._idx += 1
        if self._idx % config.MMA_N == 0:
            self._settled = False         # next element starts a new row
        if self._idx == config.MMA_M * config.MMA_N:
            self.busy = False
            self.bars.arrive(self._bar)
