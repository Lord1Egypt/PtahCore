"""cocotb: mac_cell.sv — accumulation chains bit-exact vs numpy float32."""

import struct
import sys
from pathlib import Path

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge
import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))


def bits(v) -> int:
    return struct.unpack("<I", struct.pack("<f", float(np.float32(v))))[0]


async def _reset(dut):
    dut.rst.value = 1
    dut.en.value = 0
    dut.zero.value = 0
    dut.slot.value = 0
    dut.a_f32.value = 0
    dut.b_f32.value = 0
    dut.drain_slot.value = 0
    await RisingEdge(dut.clk)
    await RisingEdge(dut.clk)
    dut.rst.value = 0
    await RisingEdge(dut.clk)


@cocotb.test()
async def mac_chain_bit_exact(dut):
    """32-step MAC chain on slot 0, then verify drain — vs numpy fp32."""
    cocotb.start_soon(Clock(dut.clk, 2, "ns").start())
    await _reset(dut)

    rng = np.random.default_rng(21)
    a_vals = rng.uniform(-448, 448, 32).astype(np.float32)
    b_vals = rng.uniform(-1, 1, 32).astype(np.float32)

    acc = np.float32(0)
    for k in range(32):
        dut.en.value = 1
        dut.zero.value = 1 if k == 0 else 0
        dut.slot.value = 0
        dut.a_f32.value = bits(a_vals[k])
        dut.b_f32.value = bits(b_vals[k])
        await RisingEdge(dut.clk)
        prod = np.float32(a_vals[k] * b_vals[k])
        acc = np.float32((np.float32(0) if k == 0 else acc) + prod)
    dut.en.value = 0
    await RisingEdge(dut.clk)

    dut.drain_slot.value = 0
    await RisingEdge(dut.clk)
    got = int(dut.drain_out.value)
    assert got == bits(acc), f"chain: got {got:#010x} want {bits(acc):#010x}"


@cocotb.test()
async def slots_independent(dut):
    cocotb.start_soon(Clock(dut.clk, 2, "ns").start())
    await _reset(dut)

    expect = {}
    for slot, v in [(0, 3.0), (1, 5.0), (2, -7.0), (3, 11.0)]:
        dut.en.value = 1
        dut.zero.value = 1
        dut.slot.value = slot
        dut.a_f32.value = bits(v)
        dut.b_f32.value = bits(2.0)
        await RisingEdge(dut.clk)
        expect[slot] = np.float32(v * 2.0)
    dut.en.value = 0
    await RisingEdge(dut.clk)

    for slot, want in expect.items():
        dut.drain_slot.value = slot
        await RisingEdge(dut.clk)
        got = int(dut.drain_out.value)
        assert got == bits(want), f"slot {slot}: {got:#010x} != {bits(want):#010x}"


@cocotb.test()
async def en_low_holds_state(dut):
    cocotb.start_soon(Clock(dut.clk, 2, "ns").start())
    await _reset(dut)

    dut.en.value = 1
    dut.zero.value = 1
    dut.slot.value = 0
    dut.a_f32.value = bits(10.0)
    dut.b_f32.value = bits(10.0)
    await RisingEdge(dut.clk)
    dut.en.value = 0
    dut.a_f32.value = bits(999.0)   # garbage on the bus, en low
    for _ in range(5):
        await RisingEdge(dut.clk)

    dut.drain_slot.value = 0
    await RisingEdge(dut.clk)
    assert int(dut.drain_out.value) == bits(np.float32(100.0))
