"""cocotb: smem.sv + barrier.sv vs their pymodel twins."""

import sys
from pathlib import Path

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge
import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))


# ── smem ─────────────────────────────────────────────────────────────

async def _smem_write16(dut, addr, data16: bytes):
    dut.wr_en.value = 1
    dut.wr_addr.value = addr
    dut.wr_data.value = int.from_bytes(data16, "little")
    await RisingEdge(dut.clk)
    dut.wr_en.value = 0


@cocotb.test()
async def smem_write_read_roundtrip(dut):
    if "smem" not in dut._name:
        return
    cocotb.start_soon(Clock(dut.clk, 2, "ns").start())
    dut.wr_en.value = 0
    dut.rd_a_addr.value = 0
    dut.rd_b_addr.value = 0
    await RisingEdge(dut.clk)

    rng = np.random.default_rng(5)
    base = 4096
    blob = rng.integers(0, 256, 64, dtype=np.uint8).tobytes()
    for i in range(0, 64, 16):
        await _smem_write16(dut, base + i, blob[i:i + 16])

    # read 32 B from both ports at different offsets; registered: next cycle
    dut.rd_a_addr.value = base
    dut.rd_b_addr.value = base + 32
    await RisingEdge(dut.clk)
    await RisingEdge(dut.clk)
    got_a = int(dut.rd_a_data.value).to_bytes(32, "little")
    got_b = int(dut.rd_b_data.value).to_bytes(32, "little")
    assert got_a == blob[:32], "port A mismatch"
    assert got_b == blob[32:], "port B mismatch"


@cocotb.test()
async def smem_ports_independent_same_cycle(dut):
    if "smem" not in dut._name:
        return
    cocotb.start_soon(Clock(dut.clk, 2, "ns").start())
    dut.wr_en.value = 0
    await RisingEdge(dut.clk)

    a16 = bytes(range(16))
    b16 = bytes(range(16, 32))
    await _smem_write16(dut, 512, a16)
    await _smem_write16(dut, 1024, b16)

    dut.rd_a_addr.value = 512
    dut.rd_b_addr.value = 1024
    await RisingEdge(dut.clk)
    await RisingEdge(dut.clk)
    assert int(dut.rd_a_data.value).to_bytes(32, "little")[:16] == a16
    assert int(dut.rd_b_data.value).to_bytes(32, "little")[:16] == b16


# ── barrier ──────────────────────────────────────────────────────────

async def _bar_reset(dut):
    cocotb.start_soon(Clock(dut.clk, 2, "ns").start())
    dut.rst.value = 1
    for sig in ("init_en", "tx_en", "arr0_en", "arr1_en", "arr2_en"):
        getattr(dut, sig).value = 0
    await RisingEdge(dut.clk)
    await RisingEdge(dut.clk)
    dut.rst.value = 0
    await RisingEdge(dut.clk)


async def _bar_init(dut, bar, count):
    dut.init_en.value = 1
    dut.init_bar.value = bar
    dut.init_count.value = count
    await RisingEdge(dut.clk)
    dut.init_en.value = 0


async def _arrive1(dut, bar):
    dut.arr1_en.value = 1
    dut.arr1_bar.value = bar
    await RisingEdge(dut.clk)
    dut.arr1_en.value = 0


def _phase(dut, bar):
    return (int(dut.phase_q.value) >> bar) & 1


@cocotb.test()
async def barrier_flip_and_reload(dut):
    if "barrier" not in dut._name:
        return
    await _bar_reset(dut)
    await _bar_init(dut, 3, 2)
    await RisingEdge(dut.clk)
    assert _phase(dut, 3) == 0

    await _arrive1(dut, 3)
    await RisingEdge(dut.clk)
    assert _phase(dut, 3) == 0          # 1 of 2

    await _arrive1(dut, 3)
    await RisingEdge(dut.clk)
    assert _phase(dut, 3) == 1          # flipped

    # reloaded: two more arrivals flip back
    await _arrive1(dut, 3)
    await _arrive1(dut, 3)
    await RisingEdge(dut.clk)
    assert _phase(dut, 3) == 0


@cocotb.test()
async def barrier_tx_blocks_flip(dut):
    if "barrier" not in dut._name:
        return
    await _bar_reset(dut)
    await _bar_init(dut, 1, 1)

    # LOAD issue: tx += 64
    dut.tx_en.value = 1
    dut.tx_bar.value = 1
    dut.tx_bytes.value = 64
    await RisingEdge(dut.clk)
    dut.tx_en.value = 0

    # arrival with only half the tx retired must NOT flip
    dut.arr0_en.value = 1
    dut.arr0_bar.value = 1
    dut.arr0_txdone.value = 32
    await RisingEdge(dut.clk)
    dut.arr0_en.value = 0
    await RisingEdge(dut.clk)
    assert _phase(dut, 1) == 0, "flipped with tx outstanding"


@cocotb.test()
async def barrier_load_completion_flips(dut):
    if "barrier" not in dut._name:
        return
    await _bar_reset(dut)
    await _bar_init(dut, 2, 1)

    dut.tx_en.value = 1
    dut.tx_bar.value = 2
    dut.tx_bytes.value = 128
    await RisingEdge(dut.clk)
    dut.tx_en.value = 0

    dut.arr0_en.value = 1
    dut.arr0_bar.value = 2
    dut.arr0_txdone.value = 128
    await RisingEdge(dut.clk)
    dut.arr0_en.value = 0
    await RisingEdge(dut.clk)
    assert _phase(dut, 2) == 1


@cocotb.test()
async def barrier_same_cycle_multi_arrive(dut):
    """LOAD + MMA + STORE arriving on the same barrier in one cycle."""
    if "barrier" not in dut._name:
        return
    await _bar_reset(dut)
    await _bar_init(dut, 5, 3)

    dut.tx_en.value = 1
    dut.tx_bar.value = 5
    dut.tx_bytes.value = 16
    await RisingEdge(dut.clk)
    dut.tx_en.value = 0

    dut.arr0_en.value = 1
    dut.arr0_bar.value = 5
    dut.arr0_txdone.value = 16
    dut.arr1_en.value = 1
    dut.arr1_bar.value = 5
    dut.arr2_en.value = 1
    dut.arr2_bar.value = 5
    await RisingEdge(dut.clk)
    dut.arr0_en.value = 0
    dut.arr1_en.value = 0
    dut.arr2_en.value = 0
    await RisingEdge(dut.clk)
    assert _phase(dut, 5) == 1, "3 same-cycle arrivals should complete count=3"
