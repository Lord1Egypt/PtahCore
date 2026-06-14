"""cocotb: mac_array_sparse.sv — the 2:4 sparse MAC datapath, K/2 steps,
bit-exact vs golden (dense matmul of the decompressed A).

Built at M=N=4, K=8 (-G): HALFK=4 kept values/row, GROUPS=2, NSTEP=4 steps
(vs 8 dense → the 2× is structural). Drives compressed A (a_vals + a_meta)
+ dense B, runs, drains every accumulator, asserts == matmul_reference_sparse.
"""

import struct
import sys
from pathlib import Path

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer
import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))
from golden.sparse24 import (compress, matmul_reference_sparse,  # noqa: E402
                             random_sparse_a)

M, N, K = 4, 4, 8


def f32(b):
    return struct.unpack("<f", struct.pack("<I", b & 0xFFFFFFFF))[0]


def _flat(arr):
    return int.from_bytes(arr.astype(np.uint8).tobytes(), "little")


async def _run(dut, a_vals, a_meta, b, slot, accum, fmt=0):
    dut.start.value = 1
    dut.a_vals.value = _flat(a_vals)
    dut.a_meta.value = _flat(a_meta)
    dut.b_tile.value = _flat(b)
    dut.start_slot.value = slot
    dut.start_accum.value = accum
    dut.start_fmt.value = fmt
    await RisingEdge(dut.clk)
    dut.start.value = 0
    for _ in range(K + 12):
        await RisingEdge(dut.clk)
        if int(dut.done.value):
            break
    else:
        assert False, "mac_array_sparse never asserted done"
    await RisingEdge(dut.clk)


async def _reset(dut):
    cocotb.start_soon(Clock(dut.clk, 2, "ns").start())
    dut.rst.value = 1
    dut.start.value = 0
    dut.a_vals.value = 0
    dut.a_meta.value = 0
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


async def _check_drain(dut, slot, ref):
    dut.drain_slot.value = slot
    for idx in range(M * N):
        dut.drain_idx.value = idx
        await Timer(1, "ns")
        got = f32(int(dut.drain_data.value))
        assert got == ref.ravel()[idx], f"idx {idx}: {got} != {ref.ravel()[idx]}"


@cocotb.test()
async def sparse_matmul_bit_exact(dut):
    rng = np.random.default_rng(1)
    dense_a = random_sparse_a(rng, M, K, "e4m3")
    a_vals, a_meta = compress(dense_a)
    b = rng.integers(0, 120, (N, K), dtype=np.uint8)   # small finite fp8

    await _reset(dut)
    await _run(dut, a_vals, a_meta, b, slot=0, accum=0)
    await _check_drain(dut, 0, matmul_reference_sparse(a_vals, a_meta, b, "e4m3"))


@cocotb.test()
async def sparse_accumulate(dut):
    """accum=1: a second sparse tile accumulates onto the first, in fp32."""
    rng = np.random.default_rng(2)
    da0 = random_sparse_a(rng, M, K, "e4m3")
    da1 = random_sparse_a(rng, M, K, "e4m3")
    av0, am0 = compress(da0)
    av1, am1 = compress(da1)
    b0 = rng.integers(0, 120, (N, K), dtype=np.uint8)
    b1 = rng.integers(0, 120, (N, K), dtype=np.uint8)

    await _reset(dut)
    await _run(dut, av0, am0, b0, slot=1, accum=0)
    await _run(dut, av1, am1, b1, slot=1, accum=1)

    ref0 = matmul_reference_sparse(av0, am0, b0, "e4m3")
    ref1 = matmul_reference_sparse(av1, am1, b1, "e4m3")
    await _check_drain(dut, 1, (ref0 + ref1).astype(np.float32))


@cocotb.test()
async def sparse_takes_half_steps(dut):
    """Throughput: done after NSTEP=K/2 multiply cycles, not K."""
    rng = np.random.default_rng(3)
    a_vals, a_meta = compress(random_sparse_a(rng, M, K, "e4m3"))
    b = rng.integers(0, 120, (N, K), dtype=np.uint8)
    await _reset(dut)

    dut.start.value = 1
    dut.a_vals.value = _flat(a_vals)
    dut.a_meta.value = _flat(a_meta)
    dut.b_tile.value = _flat(b)
    await RisingEdge(dut.clk)
    dut.start.value = 0
    cycles = 0
    while not int(dut.done.value):
        await RisingEdge(dut.clk)
        cycles += 1
        assert cycles < 50
    # NSTEP=K/2 multiply cycles + the cell's 2-stage flush (prod reg +
    # accumulate reg). The point: latency scales with K/2, not K — a dense
    # tile of the same K would drive K multiply cycles (2× the work).
    assert cycles == K // 2 + 2, f"done after {cycles} cycles, want {K // 2 + 2}"
