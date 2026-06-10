"""cocotb: cmdproc (+ real barrier) — decode, REPEAT strides, auto-phase WAIT.

The TB plays the role of the three engines: it records every start strobe
and drives completion arrivals into the barrier to unblock WAITs.
"""

import sys
from pathlib import Path

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, ReadOnly

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))

# ── instruction packer (mirrors cmdproc.sv field map) ────────────────
OP = dict(BARINIT=0, LOAD=1, MMA=2, STORE=3, WAIT=4, REPEAT=5)


def _pack(op, bar=0, a16=0, b16=0, g32=0, n32=0, slot=0, accdt=0, fmt=0,
          s0=0, s1=0):
    w = (op & 0xF)
    w |= (bar & 0xF) << 4
    w |= (a16 & 0xFFFF) << 8
    w |= (b16 & 0xFFFF) << 24
    w |= (g32 & 0xFFFFFFFF) << 40
    w |= (n32 & 0xFFFFFFFF) << 72
    w |= (slot & 0x3) << 104
    w |= (accdt & 1) << 106
    w |= (fmt & 1) << 107
    w |= (s0 & 0xFFFF) << 108
    w |= (s1 & 0xFFFF) << 124
    return w


def barinit(bar, count): return _pack(OP["BARINIT"], bar=bar, a16=count)
def load(bar, g, s, n, gstep=0, sstep=0):
    return _pack(OP["LOAD"], bar=bar, a16=s, g32=g, n32=n, s0=gstep, s1=sstep)
def mma(bar, a, b, slot=0, accum=0, fmt=0, astep=0, bstep=0):
    return _pack(OP["MMA"], bar=bar, a16=a, b16=b, slot=slot, accdt=accum,
                 fmt=fmt, s0=astep, s1=bstep)
def store(bar, g, slot=0, dtype=0, gstep=0):
    return _pack(OP["STORE"], bar=bar, g32=g, slot=slot, accdt=dtype, s0=gstep)
def wait(bar): return _pack(OP["WAIT"], bar=bar)
def repeat(count, length): return _pack(OP["REPEAT"], a16=count, b16=length)


async def _reset(dut):
    cocotb.start_soon(Clock(dut.clk, 2, "ns").start())
    dut.rst.value = 1
    for s in ("push_en", "ld_busy", "mma_busy", "st_busy",
              "arr0_en", "arr1_en", "arr2_en"):
        getattr(dut, s).value = 0
    dut.push_instr.value = 0
    dut.arr0_bar.value = 0
    dut.arr0_txdone.value = 0
    dut.arr1_bar.value = 0
    dut.arr2_bar.value = 0
    await RisingEdge(dut.clk)
    await RisingEdge(dut.clk)
    dut.rst.value = 0
    await RisingEdge(dut.clk)


class Recorder:
    """Drives pushes AND captures engine start strobes every cycle, so a
    start that fires while the FIFO is still being filled is never missed."""
    def __init__(self):
        self.loads = []
        self.mmas = []
        self.stores = []

    async def run(self, dut, cycles, push=None, arrivals=None):
        push = list(push or [])
        arrivals = arrivals or {}
        for c in range(cycles):
            # push one queued instruction this cycle
            if push:
                dut.push_en.value = 1
                dut.push_instr.value = push.pop(0)
            else:
                dut.push_en.value = 0
            # schedule arrival for this cycle
            a = arrivals.get(c)
            if a:
                kind, bar = a
                idx = {"ld": 0, "mma": 1, "st": 2}[kind]
                getattr(dut, f"arr{idx}_en").value = 1
                getattr(dut, f"arr{idx}_bar").value = bar
                if idx == 0:
                    dut.arr0_txdone.value = 0
            await ReadOnly()
            if int(dut.ld_start.value):
                self.loads.append((int(dut.ld_bar.value), int(dut.ld_gmem.value),
                                   int(dut.ld_smem.value), int(dut.ld_nbytes.value)))
            if int(dut.mma_start.value):
                self.mmas.append((int(dut.mma_a.value), int(dut.mma_b.value),
                                  int(dut.mma_slot.value), int(dut.mma_accum.value)))
            if int(dut.st_start.value):
                self.stores.append((int(dut.st_bar.value), int(dut.st_gmem.value),
                                    int(dut.st_slot.value), int(dut.st_dtype.value)))
            await RisingEdge(dut.clk)
            dut.push_en.value = 0
            for i in (0, 1, 2):
                getattr(dut, f"arr{i}_en").value = 0


@cocotb.test()
async def decode_each_opcode(dut):
    await _reset(dut)
    rec = Recorder()
    await rec.run(dut, 12, push=[
        barinit(0, 1),
        load(0, g=0x1000, s=0x100, n=256),
        mma(1, a=0x100, b=0x200, slot=2, accum=1, fmt=1),
        store(3, g=0x8000, slot=2, dtype=1),
    ])
    assert rec.loads == [(0, 0x1000, 0x100, 256)], rec.loads
    assert rec.mmas == [(0x100, 0x200, 2, 1)], rec.mmas
    assert rec.stores == [(3, 0x8000, 2, 1)], rec.stores


@cocotb.test()
async def engine_busy_stalls_issue(dut):
    """LOAD must not issue while ld_busy; it retries when freed."""
    await _reset(dut)
    rec = Recorder()
    dut.ld_busy.value = 1
    await rec.run(dut, 5, push=[load(0, g=0x10, s=0x100, n=16)])
    assert rec.loads == [], "issued while busy"
    dut.ld_busy.value = 0
    await rec.run(dut, 4)
    assert rec.loads == [(0, 0x10, 0x100, 16)], rec.loads


@cocotb.test()
async def repeat_applies_strides(dut):
    """REPEAT count=3 over a LOAD with gstep=AB issues 3 strided loads."""
    await _reset(dut)
    rec = Recorder()
    AB = 0x400
    await rec.run(dut, 12, push=[
        barinit(0, 1),
        repeat(3, 1),
        load(0, g=0x2000, s=0x100, n=AB, gstep=AB),
    ])
    assert rec.loads == [
        (0, 0x2000, 0x100, AB),
        (0, 0x2000 + AB, 0x100, AB),
        (0, 0x2000 + 2 * AB, 0x100, AB),
    ], rec.loads


@cocotb.test()
async def wait_blocks_until_barrier_flips(dut):
    """WAIT stalls the front-end; an MMA after it only issues post-flip."""
    await _reset(dut)
    rec = Recorder()
    await rec.run(dut, 14, push=[
        barinit(5, 1),
        wait(5),
        mma(0, a=0x1, b=0x2, slot=0),
    ], arrivals={8: ("mma", 5)})
    assert rec.mmas == [(0x1, 0x2, 0, 0)], (
        f"MMA should issue once after flip: {rec.mmas}")


@cocotb.test()
async def kloop_repeat_with_wait_inside(dut):
    """Auto-phase WAIT inside a REPEAT body: 2 iterations, each waits then MMAs."""
    await _reset(dut)
    rec = Recorder()
    await rec.run(dut, 18, push=[
        barinit(1, 1),
        repeat(2, 2),
        wait(1),
        mma(1, a=0x10, b=0x20, slot=0, accum=1),
    ], arrivals={6: ("mma", 1), 12: ("mma", 1)})
    assert len(rec.mmas) == 2, f"expected 2 MMAs, got {rec.mmas}"
    assert all(m == (0x10, 0x20, 0, 1) for m in rec.mmas), rec.mmas
