"""cocotb: mma_unit.sv — fetch tiles from a behavioral SMEM, MMA, drain.

Built at M=N=4, K=8 (-G) so A_BYTES=B_BYTES=32 = exactly RD_BYTES → one
fetch chunk, keeping the build small. Verifies the fetch FSM assembles
the operand registers correctly and the result is bit-exact vs golden.
"""

import struct
import sys
from pathlib import Path

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import FallingEdge, ReadOnly, RisingEdge, Timer
import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))
from golden.fp8 import decode_array  # noqa: E402

M, N, K = 4, 4, 8
RD = 32


def _ref(a, b, fmt, acc=None):
    af = decode_array(a, fmt).astype(np.float32)
    bf = decode_array(b, fmt).astype(np.float32)
    d = np.zeros((M, N), np.float32) if acc is None else acc.copy()
    for k in range(K):
        d += (af[:, k:k+1] * bf[:, k:k+1].T).astype(np.float32)
    return d


def f32(b):
    return struct.unpack("<f", struct.pack("<I", b))[0]


def _rand(seed, rows, fmt):
    rng = np.random.default_rng(seed)
    t = rng.integers(0, 256, (rows, K), dtype=np.uint8)
    t[~np.isfinite(decode_array(t, fmt))] = 0
    return t


async def _smem_server(dut, mem: bytes):
    """Model the registered SMEM read ports: data valid the cycle after addr."""
    while True:
        await ReadOnly()
        aa = int(dut.rd_a_addr.value)
        ba = int(dut.rd_b_addr.value)
        a_chunk = mem[aa:aa + RD].ljust(RD, b"\x00")
        b_chunk = mem[ba:ba + RD].ljust(RD, b"\x00")
        await RisingEdge(dut.clk)
        dut.rd_a_data.value = int.from_bytes(a_chunk, "little")
        dut.rd_b_data.value = int.from_bytes(b_chunk, "little")


async def _reset(dut):
    cocotb.start_soon(Clock(dut.clk, 2, "ns").start())
    dut.rst.value = 1
    dut.start.value = 0
    dut.a_smem.value = 0
    dut.b_smem.value = 0
    dut.slot.value = 0
    dut.accum.value = 0
    dut.fmt.value = 0
    dut.drain_slot.value = 0
    dut.drain_idx.value = 0
    dut.rd_a_data.value = 0
    dut.rd_b_data.value = 0
    await RisingEdge(dut.clk)
    await RisingEdge(dut.clk)
    dut.rst.value = 0
    await RisingEdge(dut.clk)


@cocotb.test()
async def fetch_mma_drain_bit_exact(dut):
    a = _rand(1, M, "e4m3")
    b = _rand(2, N, "e4m3")
    # SMEM: A tile at offset 0x100, B tile at 0x140 (past barrier region)
    A_OFF, B_OFF = 0x100, 0x140
    mem = bytearray(0x400)
    mem[A_OFF:A_OFF + M * K] = a.tobytes()
    mem[B_OFF:B_OFF + N * K] = b.tobytes()

    await _reset(dut)
    cocotb.start_soon(_smem_server(dut, bytes(mem)))

    dut.a_smem.value = A_OFF
    dut.b_smem.value = B_OFF
    dut.slot.value = 0
    dut.accum.value = 0
    dut.fmt.value = 0
    dut.start.value = 1
    await RisingEdge(dut.clk)
    dut.start.value = 0

    for _ in range(K + 12):
        await RisingEdge(dut.clk)
        if int(dut.done.value):
            break
    else:
        assert False, "mma_unit never asserted done"
    await RisingEdge(dut.clk)

    ref = _ref(a, b, "e4m3").ravel()
    dut.drain_slot.value = 0
    for idx in range(M * N):
        await FallingEdge(dut.clk)
        dut.drain_idx.value = idx
        await RisingEdge(dut.clk)
        await ReadOnly()
        got = f32(int(dut.drain_data.value))
        await RisingEdge(dut.clk)
        assert got == ref[idx], f"idx {idx}: {got} != {ref[idx]}"


@cocotb.test()
async def accumulate_two_tiles(dut):
    a0, b0 = _rand(3, M, "e4m3"), _rand(4, N, "e4m3")
    a1, b1 = _rand(5, M, "e4m3"), _rand(6, N, "e4m3")
    mem = bytearray(0x400)
    mem[0x100:0x100 + M * K] = a0.tobytes()
    mem[0x140:0x140 + N * K] = b0.tobytes()
    mem[0x180:0x180 + M * K] = a1.tobytes()
    mem[0x1C0:0x1C0 + N * K] = b1.tobytes()

    await _reset(dut)
    cocotb.start_soon(_smem_server(dut, bytes(mem)))

    async def run(a_off, b_off, accum):
        dut.a_smem.value = a_off
        dut.b_smem.value = b_off
        dut.slot.value = 1
        dut.accum.value = accum
        dut.start.value = 1
        await RisingEdge(dut.clk)
        dut.start.value = 0
        for _ in range(K + 12):
            await RisingEdge(dut.clk)
            if int(dut.done.value):
                break
        await RisingEdge(dut.clk)

    await run(0x100, 0x140, 0)
    await run(0x180, 0x1C0, 1)

    # chain: run1 accumulates onto run0's result in fp32 (matches HW order)
    ref = _ref(a1, b1, "e4m3", acc=_ref(a0, b0, "e4m3")).ravel()
    dut.drain_slot.value = 1
    for idx in range(M * N):
        await FallingEdge(dut.clk)
        dut.drain_idx.value = idx
        await RisingEdge(dut.clk)
        await ReadOnly()
        got = f32(int(dut.drain_data.value))
        await RisingEdge(dut.clk)
        assert got == ref[idx], f"idx {idx}"
