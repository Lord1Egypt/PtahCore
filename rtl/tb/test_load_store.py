"""cocotb: load.sv / store.sv vs pymodel twins — data + barrier protocol."""

import struct
import sys
from pathlib import Path

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, ReadOnly, Timer
import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))
from golden.fp8 import encode  # noqa: E402


def f32bits(v) -> int:
    return struct.unpack("<I", struct.pack("<f", float(np.float32(v))))[0]


# ── load ─────────────────────────────────────────────────────────────

@cocotb.test()
async def load_moves_all_bytes_then_done(dut):
    if dut._name != "load":
        return
    cocotb.start_soon(Clock(dut.clk, 2, "ns").start())
    rng = np.random.default_rng(17)
    gmem = rng.integers(0, 256, 1 << 16, dtype=np.uint8)
    smem = {}

    dut.rst.value = 1
    dut.start.value = 0
    dut.gmem_rd_data.value = 0
    await RisingEdge(dut.clk)
    await RisingEdge(dut.clk)
    dut.rst.value = 0
    await RisingEdge(dut.clk)

    NB = 256
    dut.start.value = 1
    dut.start_bar.value = 7
    dut.start_gmem.value = 0x1000
    dut.start_smem.value = 0x400
    dut.start_nbytes.value = NB
    await RisingEdge(dut.clk)         # latches start; cur=0 next cycle
    dut.start.value = 0

    done_seen = False
    for _ in range(NB // 16 + 4):
        await Timer(0)               # let post-edge combinational settle
        ga = int(dut.gmem_rd_addr.value)
        dut.gmem_rd_data.value = int.from_bytes(gmem[ga:ga + 16].tobytes(),
                                                "little")
        await ReadOnly()             # gmem_rd_data → smem_wr_data propagated
        if int(dut.smem_wr_en.value):
            smem[int(dut.smem_wr_addr.value)] = int(
                dut.smem_wr_data.value).to_bytes(16, "little")
        if int(dut.done.value):
            done_seen = True
            assert int(dut.done_bar.value) == 7
            assert int(dut.done_txbytes.value) == NB
        await RisingEdge(dut.clk)
        if done_seen:
            break
    assert done_seen, "LOAD never pulsed done"

    moved = b"".join(smem[a] for a in sorted(smem))
    assert moved == gmem[0x1000:0x1000 + NB].tobytes(), "payload mismatch"
    assert not int(dut.busy.value)


# ── store ────────────────────────────────────────────────────────────

async def _store_run(dut, tile_f32, dtype):
    """Drive a full drain; returns {addr: (data, nbytes)} writes."""
    cocotb.start_soon(Clock(dut.clk, 2, "ns").start())
    dut.rst.value = 1
    dut.start.value = 0
    dut.drain_data.value = 0
    await RisingEdge(dut.clk)
    await RisingEdge(dut.clk)
    dut.rst.value = 0
    await RisingEdge(dut.clk)

    dut.start.value = 1
    dut.start_bar.value = 4
    dut.start_gmem.value = 0x8000
    dut.start_slot.value = 1
    dut.start_dtype.value = dtype
    await RisingEdge(dut.clk)
    dut.start.value = 0

    writes = {}
    flat = tile_f32.ravel()
    for _ in range(len(flat) + 4):
        await Timer(0)               # post-edge combinational settle
        idx = int(dut.drain_idx.value)
        assert int(dut.drain_slot.value) == 1
        dut.drain_data.value = f32bits(flat[idx]) if idx < len(flat) else 0
        await ReadOnly()             # drain_data → gmem_wr_data propagated
        done = bool(int(dut.done.value))
        if int(dut.gmem_wr_en.value):
            writes[int(dut.gmem_wr_addr.value)] = (
                int(dut.gmem_wr_data.value), int(dut.gmem_wr_nbytes.value))
        if done:
            assert int(dut.done_bar.value) == 4
        await RisingEdge(dut.clk)
        if done:
            break
    return writes


@cocotb.test()
async def store_fp32_path(dut):
    if dut._name != "store":
        return
    rng = np.random.default_rng(23)
    tile = (rng.uniform(-1000, 1000, (32, 32))).astype(np.float32)
    w = await _store_run(dut, tile, dtype=0)
    flat = tile.ravel()
    assert len(w) == 1024
    for i, v in enumerate(flat):
        data, nb = w[0x8000 + i * 4]
        assert nb == 4
        assert data == f32bits(v), f"elem {i}"


@cocotb.test()
async def store_fp8_path(dut):
    if dut._name != "store":
        return
    rng = np.random.default_rng(29)
    tile = (rng.uniform(-600, 600, (32, 32))).astype(np.float32)
    w = await _store_run(dut, tile, dtype=1)
    flat = tile.ravel()
    assert len(w) == 1024
    for i, v in enumerate(flat):
        data, nb = w[0x8000 + i]
        assert nb == 1
        want = encode(float(v), "e4m3")
        assert (data & 0xFF) == want, (
            f"elem {i}: {v} → {data & 0xFF:#04x} want {want:#04x}")
