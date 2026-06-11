"""cocotb: mac_tile.sv — abutment tile: feedthroughs, drain chain, MAC core.

The tile is a verified mac_cell plus the TILE_SPEC boundary; these tests
pin down the boundary contract (west→east and north→south feedthroughs,
row_hit drain chain) and prove the wrapped core still MACs bit-exact.
"""

import struct
import sys
from pathlib import Path

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ReadOnly, RisingEdge, Timer
import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))


def bits(v) -> int:
    return struct.unpack("<I", struct.pack("<f", float(np.float32(v))))[0]


async def _reset(dut):
    dut.rst_in.value = 1
    dut.en_in.value = 0
    dut.zero_in.value = 0
    dut.slot_in.value = 0
    dut.drain_slot_in.value = 0
    dut.row_hit_in.value = 1
    dut.a_in.value = 0
    dut.b_in.value = 0
    dut.drain_n_in.value = 0
    await RisingEdge(dut.clk_in)
    await RisingEdge(dut.clk_in)
    dut.rst_in.value = 0
    await RisingEdge(dut.clk_in)


@cocotb.test()
async def feedthroughs_are_wires(dut):
    """Every west-in appears on east-out, every north-in on south-out."""
    cocotb.start_soon(Clock(dut.clk_in, 2, "ns").start())
    await _reset(dut)

    for en, zero, slot, dslot, hit, a, b in [
        (1, 0, 2, 3, 1, bits(1.5), bits(-2.0)),
        (0, 1, 1, 0, 0, bits(-448.0), bits(0.25)),
    ]:
        await Timer(0, "ns")
        dut.en_in.value = en
        dut.zero_in.value = zero
        dut.slot_in.value = slot
        dut.drain_slot_in.value = dslot
        dut.row_hit_in.value = hit
        dut.a_in.value = a
        dut.b_in.value = b
        await ReadOnly()
        assert int(dut.en_out.value) == en
        assert int(dut.zero_out.value) == zero
        assert int(dut.slot_out.value) == slot
        assert int(dut.drain_slot_out.value) == dslot
        assert int(dut.row_hit_out.value) == hit
        assert int(dut.a_out.value) == a
        assert int(dut.b_out.value) == b
        assert int(dut.rst_out.value) == int(dut.rst_in.value)
        await RisingEdge(dut.clk_in)


@cocotb.test()
async def drain_chain_select(dut):
    """row_hit=1 presents the cell's accumulator; 0 passes the north chain."""
    cocotb.start_soon(Clock(dut.clk_in, 2, "ns").start())
    await _reset(dut)

    # One MAC into slot 0: acc = 3.0 * 7.0.
    dut.en_in.value = 1
    dut.zero_in.value = 1
    dut.slot_in.value = 0
    dut.a_in.value = bits(3.0)
    dut.b_in.value = bits(7.0)
    await RisingEdge(dut.clk_in)
    dut.en_in.value = 0
    await RisingEdge(dut.clk_in)  # stage-2 settle (pipelined cell)
    await RisingEdge(dut.clk_in)

    north = 0xDEADBEEF
    await Timer(0, "ns")
    dut.drain_slot_in.value = 0
    dut.drain_n_in.value = north
    dut.row_hit_in.value = 1
    await ReadOnly()
    assert int(dut.drain_s_out.value) == bits(np.float32(3.0) * np.float32(7.0))

    await RisingEdge(dut.clk_in)
    await Timer(0, "ns")
    dut.row_hit_in.value = 0
    await ReadOnly()
    assert int(dut.drain_s_out.value) == north


@cocotb.test()
async def wrapped_core_mac_bit_exact(dut):
    """K-step MAC chain through the tile matches numpy fp32 exactly."""
    cocotb.start_soon(Clock(dut.clk_in, 2, "ns").start())
    await _reset(dut)

    rng = np.random.default_rng(7)
    K = 32
    a_vals = rng.uniform(-448, 448, K).astype(np.float32)
    b_vals = rng.uniform(-1, 1, K).astype(np.float32)

    acc = np.float32(0)
    for k in range(K):
        dut.en_in.value = 1
        dut.zero_in.value = 1 if k == 0 else 0
        dut.slot_in.value = 1
        dut.a_in.value = bits(a_vals[k])
        dut.b_in.value = bits(b_vals[k])
        await RisingEdge(dut.clk_in)
        base = np.float32(0) if k == 0 else acc
        acc = np.float32(base + np.float32(a_vals[k] * b_vals[k]))
    dut.en_in.value = 0
    await RisingEdge(dut.clk_in)

    dut.drain_slot_in.value = 1
    dut.row_hit_in.value = 1
    await RisingEdge(dut.clk_in)
    got = int(dut.drain_s_out.value)
    assert got == bits(acc), f"{got:#010x} != {bits(acc):#010x}"
