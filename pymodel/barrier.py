"""barrier — mbarrier file (NUM_BARRIERS objects).

Logically these live in SMEM's reserved prefix; the pymodel keeps them
as structured state for clarity. The RTL twin will map them to the
same SMEM byte layout (pending u16 | expected u16 | tx u32 | phase u8).

INPUTS (method calls, atomic within a cycle)
    init(bar, count)
    add_tx(bar, nbytes)        # LOAD issue-time
    arrive(bar, tx_done=0)     # engine completion; tx_done subtracted first
    phase(bar) -> 0|1

INTERNAL STATE (per barrier)
    pending  : int — arrivals remaining this phase
    expected : int — reload value
    tx       : int — bytes outstanding
    phase    : 0|1

BEHAVIOR (flip rule)
    1. After any arrive/tx update: if pending == 0 and tx == 0:
       phase ^= 1; pending = expected.

INVARIANTS
    - pending never negative; tx never negative (asserted).
"""

import config


class BarrierFile:
    def __init__(self):
        n = config.NUM_BARRIERS
        self.pending = [0] * n
        self.expected = [0] * n
        self.tx = [0] * n
        self._phase = [0] * n

    def init(self, bar: int, count: int):
        assert 0 < count < 2 ** 16
        self.pending[bar] = count
        self.expected[bar] = count
        self.tx[bar] = 0
        self._phase[bar] = 0

    def add_tx(self, bar: int, nbytes: int):
        self.tx[bar] += nbytes

    def arrive(self, bar: int, tx_done: int = 0):
        self.tx[bar] -= tx_done
        self.pending[bar] -= 1
        assert self.tx[bar] >= 0, f"bar{bar}: tx underflow"
        assert self.pending[bar] >= 0, f"bar{bar}: pending underflow"
        self._maybe_flip(bar)

    def phase(self, bar: int) -> int:
        return self._phase[bar]

    def _maybe_flip(self, bar: int):
        if self.pending[bar] == 0 and self.tx[bar] == 0:
            self._phase[bar] ^= 1
            self.pending[bar] = self.expected[bar]
