"""cocotb: mac_array.sv at a NON-NATIVE large shape — bit-exact vs golden.

Phase 10: the pymodel scaling test proves the algorithm; this proves the
*Verilog* (generate-blocks, bit-widths: $clog2(M*N) drain index, $clog2(K)
column select, row_hit[M-1:0], the M+N edge decoders) FUNCTIONS at a shape
it was never built at. Default 64×4×64 — M and K past the native 32, N kept
small so the cell count (and the Verilator/g++ build) stays tractable; the
full 64×64×64 widths/generates are covered by the lint in synth/lint_64.sh.
Shape is set once in cocotb.mk (-G + BIG_M/N/K env) and read here.
"""

import os
import struct
import sys
from pathlib import Path

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import FallingEdge, ReadOnly, RisingEdge, Timer
import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))
from golden.fp8 import decode_array  # noqa: E402

# shape must match the -G params in cocotb.mk (passed through as env)
M = int(os.environ.get("BIG_M", "64"))
N = int(os.environ.get("BIG_N", "4"))
K = int(os.environ.get("BIG_K", "64"))


def _pack_tile(bytes_2d) -> int:
    return int.from_bytes(bytes_2d.reshape(-1).astype(np.uint8).tobytes(), "little")


def _ref(a_bytes, b_bytes, fmt, acc=None):
    a = decode_array(a_bytes, fmt).astype(np.float32)
    b = decode_array(b_bytes, fmt).astype(np.float32)
    d = np.zeros((M, N), np.float32) if acc is None else acc.copy()
    for k in range(K):
        d += (a[:, k:k+1] * b[:, k:k+1].T).astype(np.float32)
    return d


def f32(b):
    return struct.unpack("<f", struct.pack("<I", b & 0xFFFFFFFF))[0]


async def _clocks(dut):
    ones_m = (1 << M) - 1
    ones_n = (1 << N) - 1
    while True:
        dut.clk.value = 0
        dut.clk_row_v.value = 0
        dut.clk_lw_v.value = 0
        dut.clk_lb_v.value = 0
        dut.clk_s.value = 0
        await Timer(1, "ns")
        dut.clk.value = 1
        dut.clk_row_v.value = ones_m
        dut.clk_lw_v.value = ones_m
        dut.clk_lb_v.value = ones_n
        dut.clk_s.value = 1
        await Timer(1, "ns")


async def _reset(dut):
    cocotb.start_soon(_clocks(dut))
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
    await RisingEdge(dut.clk)
    dut.start.value = 0
    for _ in range(K + 4):
        await RisingEdge(dut.clk)
        if int(dut.done.value):
            break
    else:
        assert False, "MMA never asserted done"
    await RisingEdge(dut.clk)


async def _drain_check(dut, slot, ref):
    flat = ref.ravel()
    dut.drain_slot.value = slot
    for idx in range(M * N):
        await FallingEdge(dut.clk)
        dut.drain_idx.value = idx
        for _ in range(4):                 # drain pipeline depth (DRAIN_LAT)
            await RisingEdge(dut.clk)
        await ReadOnly()
        got = f32(int(dut.drain_data.value))
        await RisingEdge(dut.clk)
        assert got == flat[idx], f"idx {idx}: {got} != {flat[idx]}"


def _rand(seed, rows, fmt):
    rng = np.random.default_rng(seed)
    t = rng.integers(0, 256, (rows, K), dtype=np.uint8)
    t[~np.isfinite(decode_array(t, fmt))] = 0
    return t


@cocotb.test()
async def big_shape_bit_exact(dut):
    """A full MMA at M×N×K (M,N past the native 32), bit-exact vs golden."""
    await _reset(dut)
    a, b = _rand(1, M, "e4m3"), _rand(2, N, "e4m3")
    await _run_mma(dut, a, b, slot=0, accum=0, fmt_bit=0)
    await _drain_check(dut, 0, _ref(a, b, "e4m3"))


@cocotb.test()
async def big_shape_accumulate(dut):
    await _reset(dut)
    a0, b0 = _rand(5, M, "e4m3"), _rand(6, N, "e4m3")
    a1, b1 = _rand(7, M, "e4m3"), _rand(8, N, "e4m3")
    await _run_mma(dut, a0, b0, slot=1, accum=0, fmt_bit=0)
    await _run_mma(dut, a1, b1, slot=1, accum=1, fmt_bit=0)
    # chained accumulate: tile 1 adds onto tile 0's result IN the same fp32
    # accumulator, per K-step (matches the RTL; NOT two matmuls then summed)
    ref = _ref(a1, b1, "e4m3", acc=_ref(a0, b0, "e4m3"))
    await _drain_check(dut, 1, ref)
