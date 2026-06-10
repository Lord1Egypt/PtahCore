"""sim — top-level harness: wiring + clock loop.

Tick order within a cycle (fixed; all cross-module signals are
registered so order only matters for determinism):

    1. cmdproc  — issue at most one instruction
    2. load     — move one DMA beat
    3. array    — one MMA K-step
    4. store    — drain one element
    5. MMA-done arrival — if the array pulsed `done`, fire its barrier

A hardware-faithful detail: the MMA's barrier arrival happens the cycle
the array finishes, exactly once.
"""

import numpy as np

import config
from pymodel.barrier import BarrierFile
from pymodel.cmdproc import CmdProc
from pymodel.gmem import Gmem
from pymodel.load import LoadEngine
from pymodel.mac_array import MacArray
from pymodel.smem import Smem
from pymodel.store import StoreEngine


class Sim:
    def __init__(self):
        self.gmem = Gmem()
        self.smem = Smem()
        self.bars = BarrierFile()
        self.array = MacArray()
        self.load = LoadEngine(self.gmem, self.smem, self.bars)
        self.store = StoreEngine(self.gmem, self.array, self.bars)
        self.cmdproc = CmdProc(self.load, self.array, self.store, self.bars)
        self.cycles = 0

    def push_program(self, instrs):
        for ins in instrs:
            self.cmdproc.push(ins)

    def tick(self):
        self.cmdproc.tick()
        self.load.tick()
        self.array.tick()
        self.store.tick()
        if self.array.done:
            self.bars.arrive(self.cmdproc._mma_bar)
        self.cycles += 1

    def run(self, max_cycles: int = 1_000_000):
        """Run until the whole machine drains (or trip the watchdog)."""
        for _ in range(max_cycles):
            self.tick()
            if (self.cmdproc.idle and not self.load.busy
                    and not self.array.busy and not self.store.busy):
                return self.cycles
        raise TimeoutError(f"sim watchdog: not idle after {max_cycles} cycles")

    # ── TB conveniences ──────────────────────────────────────────────
    def read_result_fp32(self, gmem_addr: int) -> np.ndarray:
        m, n = config.MMA_M, config.MMA_N
        raw = self.gmem.read(gmem_addr, m * n * 4)
        return np.frombuffer(raw, dtype="<f4").reshape(m, n).copy()

    def read_result_fp8(self, gmem_addr: int) -> np.ndarray:
        m, n = config.MMA_M, config.MMA_N
        raw = self.gmem.read(gmem_addr, m * n)
        return np.frombuffer(raw, dtype=np.uint8).reshape(m, n).copy()
