"""cocotb: mac_array.sv vs golden matmul — bit-exact.

Built at a small shape (M=N=4, K=8 via -G overrides) so the 1024-cell
full array doesn't blow up Verilator build time; the logic is identical
and config-parameterized. One test also exercises accumulate chaining.
"""

import struct
import sys
from pathlib import Path

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge
import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))
from golden.fp8 import decode_array  # noqa: E402

# shape must match the -G params in cocotb.mk
M, N, K = 4, 4, 8


def _pack_tile(bytes_2d) -> int:
    """Row-major (rows, K) uint8 → flat little-endian bit vector."""
    flat = bytes_2d.reshape(-1)
    v = 0
    for i, b in enumerate(flat):
        v |= int(b) << (8 * i)
    return v


def _ref(a_bytes, b_bytes, fmt, acc=None):
    a = decode_array(a_bytes, fmt).astype(np.float32)
    b = decode_array(b_bytes, fmt).astype(np.float32)
    d = np.zeros((M, N), np.float32) if acc is None else acc.copy()
    for k in range(K):
        d += (a[:, k:k+1] * b[:, k:k+1].T).astype(np.float32)
    return d


def f32(b):
    return struct.unpack("<f", struct.pack("<I", b))[0]


async def _reset(dut):
    cocotb.start_soon(Clock(dut.clk, 2, "ns").start())
    dut.rst.value = 1
    dut.start.value = 0
    dut.a_tile.value = 0
    dut.b_tile.value = 0
    dut.start_slot.value = 0
    dut.start_accum.value = 0
    dut.start_fmt.value = 0
    dut.drain_slot.value = 0
    dut.drain_idx.value = 0
    await RisingEdge(dut.clk)
    await RisingEdge(dut.clk)
    dut.rst.value = 0
    await RisingEdge(dut.clk)


async def _run_mma(dut, a, b, slot, accum, fmt_bit):
    dut.start.value = 1
    dut.a_tile.value = _pack_tile(a)
    dut.b_tile.value = _pack_tile(b)
    dut.start_slot.value = slot
    dut.start_accum.value = accum
    dut.start_fmt.value = fmt_bit
    await RisingEdge(dut.clk)          # latch start; busy asserts now
    dut.start.value = 0
    # MMA takes exactly K cycles; wait for the done pulse, with a guard.
    for _ in range(K + 4):
        await RisingEdge(dut.clk)
        if int(dut.done.value):
            break
    else:
        assert False, "MMA never asserted done"
    await RisingEdge(dut.clk)          # let the K-th accumulate settle


async def _drain_check(dut, slot, ref):
    flat = ref.ravel()
    dut.drain_slot.value = slot
    for idx in range(M * N):
        dut.drain_idx.value = idx
        await RisingEdge(dut.clk)
        got = f32(int(dut.drain_data.value))
        assert got == flat[idx], f"idx {idx}: {got} != {flat[idx]}"


def _rand(seed, rows, fmt):
    rng = np.random.default_rng(seed)
    t = rng.integers(0, 256, (rows, K), dtype=np.uint8)
    t[~np.isfinite(decode_array(t, fmt))] = 0
    return t


@cocotb.test()
async def single_mma_bit_exact(dut):
    await _reset(dut)
    a, b = _rand(1, M, "e4m3"), _rand(2, N, "e4m3")
    await _run_mma(dut, a, b, slot=0, accum=0, fmt_bit=0)
    await _drain_check(dut, 0, _ref(a, b, "e4m3"))


@cocotb.test()
async def e5m2_format(dut):
    await _reset(dut)
    a, b = _rand(3, M, "e5m2"), _rand(4, N, "e5m2")
    await _run_mma(dut, a, b, slot=1, accum=0, fmt_bit=1)
    await _drain_check(dut, 1, _ref(a, b, "e5m2"))


@cocotb.test()
async def accumulate_chain(dut):
    await _reset(dut)
    a0, b0 = _rand(5, M, "e4m3"), _rand(6, N, "e4m3")
    a1, b1 = _rand(7, M, "e4m3"), _rand(8, N, "e4m3")
    await _run_mma(dut, a0, b0, slot=2, accum=0, fmt_bit=0)
    await _run_mma(dut, a1, b1, slot=2, accum=1, fmt_bit=0)
    ref = _ref(a1, b1, "e4m3", acc=_ref(a0, b0, "e4m3"))
    await _drain_check(dut, 2, ref)


@cocotb.test()
async def slots_independent(dut):
    await _reset(dut)
    a, b = _rand(9, M, "e4m3"), _rand(10, N, "e4m3")
    await _run_mma(dut, a, b, slot=0, accum=0, fmt_bit=0)
    ref0 = _ref(a, b, "e4m3")
    a2, b2 = _rand(11, M, "e4m3"), _rand(12, N, "e4m3")
    await _run_mma(dut, a2, b2, slot=3, accum=0, fmt_bit=0)
    await _drain_check(dut, 0, ref0)   # slot 0 untouched by slot-3 MMA
