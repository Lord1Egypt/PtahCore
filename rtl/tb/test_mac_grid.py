"""cocotb: mac_grid.sv — M×N abutted tile sea: vertical B feedthrough,
row_hit-selected southbound drain chain, registered south strip.

Run at M=N=4 via -GM=4 -GN=4 (parameter-identical to the 32×32 build).
What the mac_array wrapper can't see is exercised here directly: B
enters ONLY row 0's north edge (rows 1.. receive it through the tiles'
b_in→b_out chains), and the drain is read per (row_hit, col) through
the pass-through muxes of every tile south of the selected row.
"""

import struct
import sys
from pathlib import Path

import cocotb
from cocotb.triggers import FallingEdge, ReadOnly, RisingEdge, Timer
import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))

M = 4
N = 4
SLOT_W = 2


def bits(v) -> int:
    return struct.unpack("<I", struct.pack("<f", float(np.float32(v))))[0]


def pack32(vals) -> int:
    word = 0
    for j, v in enumerate(vals):
        word |= bits(v) << (32 * j)
    return word


def rep(val, width, count) -> int:
    word = 0
    for i in range(count):
        word |= val << (width * i)
    return word


ALL = (1 << M) - 1


async def _clocks(dut):
    """One clock wave: every clk_v bit and clk_s toggle together (the
    chip-level spine stagger is a physical-delay contract — ARRAY_SPEC
    §2 — not a behavioral one)."""
    while True:
        dut.clk_v.value = 0
        dut.clk_s.value = 0
        await Timer(1, "ns")
        dut.clk_v.value = ALL
        dut.clk_s.value = 1
        await Timer(1, "ns")


async def _reset(dut):
    dut.rst_v.value = ALL
    dut.en_v.value = 0
    dut.zero_v.value = 0
    dut.slot_v.value = 0
    dut.dslot_v.value = 0
    dut.row_hit_v.value = 0
    dut.a_v.value = 0
    dut.b_n_flat.value = 0
    dut.drain_col_sel.value = 0
    await RisingEdge(dut.clk_s)
    await RisingEdge(dut.clk_s)
    dut.rst_v.value = 0
    await RisingEdge(dut.clk_s)


async def _mac_fill(dut, a_rows, b_cols, K, slot=0):
    """K MAC steps on every cell; returns the expected M×N accumulators."""
    acc = np.zeros((M, N), dtype=np.float32)
    for k in range(K):
        dut.en_v.value = ALL
        dut.zero_v.value = ALL if k == 0 else 0
        dut.slot_v.value = rep(slot, SLOT_W, M)
        dut.a_v.value = pack32(a_rows[k])
        dut.b_n_flat.value = pack32(b_cols[k])   # row 0's north edge ONLY
        await RisingEdge(dut.clk_s)
        for i in range(M):
            for j in range(N):
                prod = np.float32(np.float32(a_rows[k][i]) *
                                  np.float32(b_cols[k][j]))
                base = np.float32(0) if k == 0 else acc[i][j]
                acc[i][j] = np.float32(base + prod)
    dut.en_v.value = 0
    await RisingEdge(dut.clk_s)                  # pipeline flush
    return acc


async def _drain_read(dut, row, col, slot=0):
    """Registered drain: present {row_hit, col, slot} mid-cycle, value
    valid after the edge."""
    await FallingEdge(dut.clk_s)
    dut.row_hit_v.value = 1 << row
    dut.drain_col_sel.value = col
    dut.dslot_v.value = rep(slot, SLOT_W, M)
    await RisingEdge(dut.clk_s)
    await ReadOnly()
    got = int(dut.drain_data.value)
    await RisingEdge(dut.clk_s)
    return got


@cocotb.test()
async def grid_bit_exact_and_row_select(dut):
    """B from the north edge reaches every row; each (row, col) drains
    through the chain below it, bit-exact vs numpy fp32."""
    cocotb.start_soon(_clocks(dut))
    await _reset(dut)

    rng = np.random.default_rng(71)
    K = 8
    a_rows = rng.uniform(-448, 448, (K, M)).astype(np.float32)
    b_cols = rng.uniform(-1, 1, (K, N)).astype(np.float32)
    acc = await _mac_fill(dut, a_rows, b_cols, K)

    for i in range(M):
        for j in range(N):
            got = await _drain_read(dut, i, j)
            assert got == bits(acc[i][j]), (
                f"({i},{j}): got {got:#010x} want {bits(acc[i][j]):#010x}")


@cocotb.test()
async def unselected_chain_drains_zero(dut):
    """No row_hit: the south edge passes row 0's tied-zero drain_n
    through all M tiles."""
    cocotb.start_soon(_clocks(dut))
    await _reset(dut)

    rng = np.random.default_rng(72)
    a_rows = rng.uniform(-10, 10, (4, M)).astype(np.float32)
    b_cols = rng.uniform(-1, 1, (4, N)).astype(np.float32)
    await _mac_fill(dut, a_rows, b_cols, 4)      # non-zero accs everywhere

    for j in range(N):
        await FallingEdge(dut.clk_s)
        dut.row_hit_v.value = 0
        dut.drain_col_sel.value = j
        await RisingEdge(dut.clk_s)
        await ReadOnly()
        assert int(dut.drain_data.value) == 0
        await RisingEdge(dut.clk_s)


@cocotb.test()
async def slots_independent_through_chain(dut):
    """Distinct values per slot; drain both slots of the far row (full
    chain traversal) and a near row."""
    cocotb.start_soon(_clocks(dut))
    await _reset(dut)

    rng = np.random.default_rng(73)
    accs = {}
    for slot in (0, 3):
        a_rows = rng.uniform(-100, 100, (3, M)).astype(np.float32)
        b_cols = rng.uniform(-2, 2, (3, N)).astype(np.float32)
        accs[slot] = await _mac_fill(dut, a_rows, b_cols, 3, slot=slot)

    for slot in (0, 3):
        for i in (0, M - 1):
            for j in (0, N - 1):
                got = await _drain_read(dut, i, j, slot=slot)
                want = bits(accs[slot][i][j])
                assert got == want, (
                    f"slot {slot} ({i},{j}): {got:#010x} != {want:#010x}")
