"""cocotb: sparse_select.sv — the 2:4 2-of-4 lane mux, vs the golden twin.

Combinational: drive a 4-lane window + a metadata byte, check the two
selected lanes match golden.sparse24._kept_positions. Sweeps every legal
kept-lane pair and random windows, at both lane widths (8b fp8, 32b fp32).
"""

import sys
from pathlib import Path

import cocotb
from cocotb.triggers import Timer
import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))
from golden.sparse24 import _kept_positions, pack_meta  # noqa: E402

W = 32                         # must match -GW in cocotb.mk
MASK = (1 << W) - 1


async def _check(dut, lanes, meta):
    win = 0
    for p in range(4):
        win |= (lanes[p] & MASK) << (p * W)
    dut.win.value = win
    dut.meta.value = meta
    await Timer(1, "ns")
    i0, i1 = _kept_positions(meta)
    assert int(dut.sel0.value) == (lanes[i0] & MASK), f"meta {meta:#x}: sel0"
    assert int(dut.sel1.value) == (lanes[i1] & MASK), f"meta {meta:#x}: sel1"


@cocotb.test()
async def all_pairs_and_random_windows(dut):
    rng = np.random.default_rng(0)
    for i0 in range(4):
        for i1 in range(i0 + 1, 4):
            meta = pack_meta(i0, i1)
            for _ in range(40):
                lanes = [int(rng.integers(0, 1 << W, dtype=np.uint64)) for _ in range(4)]
                await _check(dut, lanes, meta)


@cocotb.test()
async def distinct_lane_values(dut):
    """Distinct per-lane sentinels make a wrong selection unambiguous."""
    lanes = [0x11111111, 0x22222222, 0x33333333, 0x44444444]
    for i0 in range(4):
        for i1 in range(i0 + 1, 4):
            await _check(dut, lanes, pack_meta(i0, i1))
