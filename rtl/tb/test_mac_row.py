"""cocotb: mac_row.sv — 1×N row, broadcast + per-column MACs vs numpy fp32.

Run at N=4 via -GN=4 (parameter-identical to the 32-wide build).
"""

import struct
import sys
from pathlib import Path

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import FallingEdge, ReadOnly, RisingEdge
import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))

N = 4


def bits(v) -> int:
    return struct.unpack("<I", struct.pack("<f", float(np.float32(v))))[0]


def pack_b(vals) -> int:
    word = 0
    for j, v in enumerate(vals):
        word |= bits(v) << (32 * j)
    return word


async def _reset(dut):
    dut.rst.value = 1
    dut.en.value = 0
    dut.zero.value = 0
    dut.slot.value = 0
    dut.a_f32.value = 0
    dut.b_f32_flat.value = 0
    dut.drain_slot.value = 0
    dut.drain_idx.value = 0
    await RisingEdge(dut.clk)
    await RisingEdge(dut.clk)
    dut.rst.value = 0
    await RisingEdge(dut.clk)


@cocotb.test()
async def row_chain_bit_exact(dut):
    """K-step MAC chains: shared A broadcast, distinct B per column."""
    cocotb.start_soon(Clock(dut.clk, 2, "ns").start())
    await _reset(dut)

    rng = np.random.default_rng(33)
    K = 16
    a_vals = rng.uniform(-448, 448, K).astype(np.float32)
    b_vals = rng.uniform(-1, 1, (K, N)).astype(np.float32)

    acc = np.zeros(N, dtype=np.float32)
    for k in range(K):
        dut.en.value = 1
        dut.zero.value = 1 if k == 0 else 0
        dut.slot.value = 0
        dut.a_f32.value = bits(a_vals[k])
        dut.b_f32_flat.value = pack_b(b_vals[k])
        await RisingEdge(dut.clk)
        for j in range(N):
            prod = np.float32(a_vals[k] * b_vals[k][j])
            base = np.float32(0) if k == 0 else acc[j]
            acc[j] = np.float32(base + prod)
    dut.en.value = 0
    await RisingEdge(dut.clk)

    for j in range(N):
        # registered drain: drive mid-cycle, value valid after the edge
        await FallingEdge(dut.clk)
        dut.drain_slot.value = 0
        dut.drain_idx.value = j
        await RisingEdge(dut.clk)
        await ReadOnly()
        got = int(dut.drain_out.value)
        await RisingEdge(dut.clk)
        assert got == bits(acc[j]), \
            f"col {j}: got {got:#010x} want {bits(acc[j]):#010x}"


@cocotb.test()
async def slots_and_columns_independent(dut):
    """One MAC per (slot, column) pair; drain every combination."""
    cocotb.start_soon(Clock(dut.clk, 2, "ns").start())
    await _reset(dut)

    expect = {}
    for slot, a in [(0, 3.0), (1, 5.0), (2, -7.0), (3, 11.0)]:
        b_row = [np.float32(j + 1) for j in range(N)]
        dut.en.value = 1
        dut.zero.value = 1
        dut.slot.value = slot
        dut.a_f32.value = bits(a)
        dut.b_f32_flat.value = pack_b(b_row)
        await RisingEdge(dut.clk)
        for j in range(N):
            expect[(slot, j)] = np.float32(np.float32(a) * b_row[j])
    dut.en.value = 0
    await RisingEdge(dut.clk)

    for (slot, j), want in expect.items():
        await FallingEdge(dut.clk)
        dut.drain_slot.value = slot
        dut.drain_idx.value = j
        await RisingEdge(dut.clk)
        await ReadOnly()
        got = int(dut.drain_out.value)
        await RisingEdge(dut.clk)
        assert got == bits(want), \
            f"slot {slot} col {j}: {got:#010x} != {bits(want):#010x}"
