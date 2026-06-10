"""load — async DMA engine, gmem → smem.

INPUTS
    start(bar, gmem, smem, nbytes) — issue; atomically bar.tx += nbytes

OUTPUTS (valid after tick)
    busy : bool

INTERNAL STATE
    cursor — bytes moved so far this transfer

BEHAVIOR (per tick)
    1. Move min(LOAD_BYTES_PER_CYCLE, remaining) bytes gmem→smem.
    2. On final beat: bar.arrive(tx_done=nbytes)  → tx -= nbytes,
       pending -= 1, flip rule evaluated.

INVARIANTS
    - nbytes multiple of 16.
    - tx is incremented at ISSUE time (before any bytes move) so a WAIT
      can never observe a window where the LOAD is in flight but
      unaccounted.
"""

import config


class LoadEngine:
    def __init__(self, gmem, smem, barriers):
        self.gmem = gmem
        self.smem = smem
        self.bars = barriers
        self.busy = False
        self._bar = 0
        self._g = 0
        self._s = 0
        self._n = 0
        self._cur = 0

    def start(self, bar: int, gmem: int, smem: int, nbytes: int):
        assert not self.busy, "LOAD issued while engine busy"
        assert nbytes % 16 == 0, f"LOAD nbytes {nbytes} not multiple of 16"
        self.bars.add_tx(bar, nbytes)          # issue-time, atomic
        self._bar, self._g, self._s, self._n = bar, gmem, smem, nbytes
        self._cur = 0
        self.busy = True

    def tick(self):
        if not self.busy:
            return
        beat = min(config.LOAD_BYTES_PER_CYCLE, self._n - self._cur)
        data = self.gmem.read(self._g + self._cur, beat)
        self.smem.write(self._s + self._cur, data)
        self._cur += beat
        if self._cur == self._n:
            self.busy = False
            self.bars.arrive(self._bar, tx_done=self._n)
