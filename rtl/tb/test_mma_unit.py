"""cocotb: mma_unit.sv — fetch tiles from a behavioral SMEM, MMA, drain.

Built at M=N=4, K=16 (-G) so A_BYTES=B_BYTES=64 = TWO fetch chunks: the
fetch pipeline (and the rd_stall retry path) is exercised mid-stream.
Verifies the fetch FSM assembles the operand registers correctly and
the result is bit-exact vs golden — with and without random stalls.
"""

import random
import struct
import sys
from pathlib import Path

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import FallingEdge, ReadOnly, RisingEdge, Timer
import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))
from golden.fp8 import decode_array  # noqa: E402

M, N, K = 4, 4, 16
RD = 32
GARBAGE = int.from_bytes(b"\xa5" * RD, "little")


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


async def _smem_server(dut, mem: bytes, stall_prob=0.0, seed=0):
    """Model the registered SMEM read ports: data valid the cycle after
    addr. With stall_prob, randomly refuse the address cycle (rd_stall
    high, smem_phys's 1RW bank-collision contract) and serve GARBAGE
    the next cycle — the fetch FSM must reissue and never capture it."""
    rng = random.Random(seed)
    while True:
        await FallingEdge(dut.clk)
        stall = rng.random() < stall_prob
        dut.rd_stall.value = 1 if stall else 0
        await ReadOnly()
        aa = int(dut.rd_a_addr.value)
        ba = int(dut.rd_b_addr.value)
        a_chunk = mem[aa:aa + RD].ljust(RD, b"\x00")
        b_chunk = mem[ba:ba + RD].ljust(RD, b"\x00")
        await RisingEdge(dut.clk)
        if stall:
            dut.rd_a_data.value = GARBAGE
            dut.rd_b_data.value = GARBAGE
        else:
            dut.rd_a_data.value = int.from_bytes(a_chunk, "little")
            dut.rd_b_data.value = int.from_bytes(b_chunk, "little")


async def _clocks(dut):
    """Drive clk and every spine-tap port in lockstep — in silicon the
    taps are phase-shifted copies of clk (CHIP_SPEC §1); in sim they
    are cycle-identical."""
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
    dut.a_smem.value = 0
    dut.b_smem.value = 0
    dut.slot.value = 0
    dut.accum.value = 0
    dut.fmt.value = 0
    dut.mx.value = 0                 # MXFP8 off — these tests are plain fp8
    dut.sa_smem.value = 0
    dut.sb_smem.value = 0
    dut.mx_lk_idx.value = 0
    dut.drain_slot.value = 0
    dut.drain_idx.value = 0
    dut.rd_a_data.value = 0
    dut.rd_b_data.value = 0
    dut.rd_stall.value = 0
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
        # drain pipeline: stage A + stage B launch, grid south register,
        # capture — data answers this idx four edges later
        for _ in range(4):
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
        # drain pipeline: stage A + stage B launch, grid south register,
        # capture — data answers this idx four edges later
        for _ in range(4):
            await RisingEdge(dut.clk)
        await ReadOnly()
        got = f32(int(dut.drain_data.value))
        await RisingEdge(dut.clk)
        assert got == ref[idx], f"idx {idx}"


@cocotb.test()
async def mx_scale_fetch_and_lookup(dut):
    """mx=1: mma_unit fetches the M+N E8M0 scales and answers store's
    per-element lookup (mx_lk_*) with the right (row, col) scale."""
    a = _rand(31, M, "e4m3")
    b = _rand(32, N, "e4m3")
    A_OFF, B_OFF, SA_OFF, SB_OFF = 0x100, 0x140, 0x180, 0x1C0
    sa = np.array([120, 127, 130, 134], np.uint8)[:M]
    sb = np.array([131, 125, 128, 122], np.uint8)[:N]
    mem = bytearray(0x400)
    mem[A_OFF:A_OFF + M * K] = a.tobytes()
    mem[B_OFF:B_OFF + N * K] = b.tobytes()
    mem[SA_OFF:SA_OFF + M] = sa.tobytes()
    mem[SB_OFF:SB_OFF + N] = sb.tobytes()

    await _reset(dut)
    cocotb.start_soon(_smem_server(dut, bytes(mem)))

    dut.a_smem.value = A_OFF
    dut.b_smem.value = B_OFF
    dut.slot.value = 1
    dut.mx.value = 1
    dut.sa_smem.value = SA_OFF
    dut.sb_smem.value = SB_OFF
    dut.start.value = 1
    await RisingEdge(dut.clk)
    dut.start.value = 0

    for _ in range(K + 16):
        await RisingEdge(dut.clk)
        if int(dut.done.value):
            break
    else:
        assert False, "mma_unit never asserted done (mx)"
    await RisingEdge(dut.clk)

    # probe the combinational scale lookup for every (i, j)
    dut.drain_slot.value = 1
    for idx in range(M * N):
        i, j = idx // N, idx % N
        dut.mx_lk_idx.value = idx
        await Timer(1, "ns")
        assert int(dut.mx_lk_en.value) == 1, f"mx_lk_en low at idx {idx}"
        assert int(dut.mx_lk_ea.value) == int(sa[i]), (
            f"idx {idx}: ea {int(dut.mx_lk_ea.value)} != {sa[i]}")
        assert int(dut.mx_lk_eb.value) == int(sb[j]), (
            f"idx {idx}: eb {int(dut.mx_lk_eb.value)} != {sb[j]}")


@cocotb.test()
async def stalled_fetch_bit_exact(dut):
    """Random rd_stall on ~40% of fetch addresses (smem_phys's 1RW
    collision contract): the FSM must reissue, never capture the
    garbage beats, and produce a bit-exact result."""
    a = _rand(7, M, "e4m3")
    b = _rand(8, N, "e4m3")
    A_OFF, B_OFF = 0x100, 0x140
    mem = bytearray(0x400)
    mem[A_OFF:A_OFF + M * K] = a.tobytes()
    mem[B_OFF:B_OFF + N * K] = b.tobytes()

    await _reset(dut)
    cocotb.start_soon(_smem_server(dut, bytes(mem), stall_prob=0.4, seed=9))

    dut.a_smem.value = A_OFF
    dut.b_smem.value = B_OFF
    dut.slot.value = 2
    dut.accum.value = 0
    dut.fmt.value = 0
    dut.start.value = 1
    await RisingEdge(dut.clk)
    dut.start.value = 0

    for _ in range(K + 24):
        await RisingEdge(dut.clk)
        if int(dut.done.value):
            break
    else:
        assert False, "mma_unit never asserted done under stalls"
    await RisingEdge(dut.clk)

    ref = _ref(a, b, "e4m3").ravel()
    dut.drain_slot.value = 2
    for idx in range(M * N):
        await FallingEdge(dut.clk)
        dut.drain_idx.value = idx
        # drain pipeline: stage A + stage B launch, grid south register,
        # capture — data answers this idx four edges later
        for _ in range(4):
            await RisingEdge(dut.clk)
        await ReadOnly()
        got = f32(int(dut.drain_data.value))
        await RisingEdge(dut.clk)
        assert got == ref[idx], f"idx {idx}: {got} != {ref[idx]}"
