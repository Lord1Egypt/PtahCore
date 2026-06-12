"""cocotb: chip_top.sv — the WHOLE chip. Push a matmul program, run it
end-to-end through real RTL, read the result out of behavioral DRAM,
assert bit-exact vs the golden model.

Built at M=N=4, K=8 (-G) so tiles are 32 B (one fetch chunk) and the
1024-cell array stays small for Verilator. The datapath is identical to
the full 32×32 configuration.
"""

import struct
import sys
from pathlib import Path

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, ReadOnly, Timer
import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))
from golden.fp8 import decode_array  # noqa: E402

M, N, K = 4, 4, 8
TILE = M * K                      # 32 bytes (A and B same size here)
BARRIER_REGION = 256

# ── instruction packer (mirrors cmdproc.sv) ──────────────────────────
OP = dict(BARINIT=0, LOAD=1, MMA=2, STORE=3, WAIT=4, REPEAT=5)


def _pack(op, bar=0, a16=0, b16=0, g32=0, n32=0, slot=0, accdt=0, fmt=0, s0=0, s1=0):
    w = (op & 0xF) | ((bar & 0xF) << 4) | ((a16 & 0xFFFF) << 8)
    w |= ((b16 & 0xFFFF) << 24) | ((g32 & 0xFFFFFFFF) << 40)
    w |= ((n32 & 0xFFFFFFFF) << 72) | ((slot & 3) << 104)
    w |= ((accdt & 1) << 106) | ((fmt & 1) << 107)
    w |= ((s0 & 0xFFFF) << 108) | ((s1 & 0xFFFF) << 124)
    return w


def barinit(bar, c): return _pack(OP["BARINIT"], bar=bar, a16=c)
def load(bar, g, s, n, gstep=0): return _pack(OP["LOAD"], bar=bar, a16=s, g32=g, n32=n, s0=gstep)
def mma(bar, a, b, slot=0, accum=0, fmt=0):
    return _pack(OP["MMA"], bar=bar, a16=a, b16=b, slot=slot, accdt=accum, fmt=fmt)
def store(bar, g, slot=0, dtype=0):
    return _pack(OP["STORE"], bar=bar, g32=g, slot=slot, accdt=dtype)
def wait(bar): return _pack(OP["WAIT"], bar=bar)
def repeat(count, length): return _pack(OP["REPEAT"], a16=count, b16=length)


def _ref(a, b, fmt):
    af = decode_array(a, fmt).astype(np.float32)
    bf = decode_array(b, fmt).astype(np.float32)
    d = np.zeros((M, N), np.float32)
    for k in range(K):
        d += (af[:, k:k+1] * bf[:, k:k+1].T).astype(np.float32)
    return d


def _rand(seed, rows, fmt):
    rng = np.random.default_rng(seed)
    t = rng.integers(0, 256, (rows, K), dtype=np.uint8)
    t[~np.isfinite(decode_array(t, fmt))] = 0
    return t


async def _dram(dut, mem: bytearray):
    """Behavioral DRAM: combinational read port + capture writes."""
    while True:
        await RisingEdge(dut.clk)
        await Timer(0)                       # let addresses settle post-edge
        a = int(dut.gmem_rd_addr.value)
        dut.gmem_rd_data.value = int.from_bytes(
            bytes(mem[a:a + 32]).ljust(32, b"\x00"), "little")
        await ReadOnly()
        if int(dut.gmem_wr_en.value):
            wa = int(dut.gmem_wr_addr.value)
            nb = int(dut.gmem_wr_nbytes.value)
            data = int(dut.gmem_wr_data.value).to_bytes(4, "little")[:nb]
            mem[wa:wa + nb] = data


async def _clocks(dut):
    """clk and the spine-root port carry the same waveform (one source
    pin in silicon; two ports so CTS owns only the logic tree)."""
    while True:
        dut.clk.value = 0
        dut.clk_spine.value = 0
        await Timer(1, "ns")
        dut.clk.value = 1
        dut.clk_spine.value = 1
        await Timer(1, "ns")


async def _reset(dut):
    cocotb.start_soon(_clocks(dut))
    dut.rst.value = 1
    dut.push_en.value = 0
    dut.push_instr.value = 0
    dut.gmem_rd_data.value = 0
    await RisingEdge(dut.clk)
    await RisingEdge(dut.clk)
    dut.rst.value = 0
    await RisingEdge(dut.clk)


async def _push(dut, instrs):
    for ins in instrs:
        dut.push_en.value = 1
        dut.push_instr.value = ins
        await RisingEdge(dut.clk)
    dut.push_en.value = 0


@cocotb.test()
async def single_tile_matmul_fp32(dut):
    a = _rand(1, M, "e4m3")
    b = _rand(2, N, "e4m3")
    A_G, B_G, D_G = 0, 64, 4096
    mem = bytearray(8192)
    mem[A_G:A_G + TILE] = a.tobytes()
    mem[B_G:B_G + TILE] = b.tobytes()

    await _reset(dut)
    cocotb.start_soon(_dram(dut, mem))

    SA, SB = BARRIER_REGION, BARRIER_REGION + TILE
    await _push(dut, [
        barinit(0, 2), barinit(1, 1), barinit(2, 1),
        load(0, A_G, SA, TILE),
        load(0, B_G, SB, TILE),
        wait(0),
        mma(1, SA, SB, slot=0, accum=0),
        wait(1),
        store(2, D_G, slot=0, dtype=0),
        wait(2),
    ])

    # run until idle + all engines quiet
    for _ in range(4000):
        await RisingEdge(dut.clk)
        if int(dut.idle.value):
            break
    else:
        assert False, "chip never went idle"
    for _ in range(8):
        await RisingEdge(dut.clk)

    ref = _ref(a, b, "e4m3").ravel()
    got = np.frombuffer(bytes(mem[D_G:D_G + M * N * 4]), dtype="<f4")
    for i in range(M * N):
        assert got[i] == ref[i], f"D[{i}] = {got[i]} != {ref[i]}"


@cocotb.test()
async def single_tile_matmul_fp8_out(dut):
    from golden.fp8 import encode
    a = _rand(3, M, "e4m3")
    b = _rand(4, N, "e4m3")
    A_G, B_G, D_G = 0, 64, 4096
    mem = bytearray(8192)
    mem[A_G:A_G + TILE] = a.tobytes()
    mem[B_G:B_G + TILE] = b.tobytes()

    await _reset(dut)
    cocotb.start_soon(_dram(dut, mem))

    SA, SB = BARRIER_REGION, BARRIER_REGION + TILE
    await _push(dut, [
        barinit(0, 2), barinit(1, 1), barinit(2, 1),
        load(0, A_G, SA, TILE), load(0, B_G, SB, TILE), wait(0),
        mma(1, SA, SB, slot=0, accum=0), wait(1),
        store(2, D_G, slot=0, dtype=1), wait(2),     # fp8 output
    ])
    for _ in range(4000):
        await RisingEdge(dut.clk)
        if int(dut.idle.value):
            break
    for _ in range(8):
        await RisingEdge(dut.clk)

    ref = _ref(a, b, "e4m3").ravel()
    want = np.array([encode(float(v), "e4m3") for v in ref], dtype=np.uint8)
    got = np.frombuffer(bytes(mem[D_G:D_G + M * N]), dtype=np.uint8)
    for i in range(M * N):
        assert got[i] == want[i], f"D[{i}] = {got[i]:#04x} != {want[i]:#04x}"


@cocotb.test()
async def kloop_repeat_multitile(dut):
    """4-tile K-loop accumulated via a REPEAT block — the whole chip, e2e.

    Tile 0 primes the accumulator (accum=0); tiles 1..3 run inside a
    REPEAT(3) body with strided gmem loads, accumulating into slot 0."""
    tiles = 4
    a_t = [_rand(10 + i, M, "e4m3") for i in range(tiles)]
    b_t = [_rand(20 + i, N, "e4m3") for i in range(tiles)]

    A_G, B_G, D_G = 0, 0x800, 0x1000
    mem = bytearray(0x4000)
    for i in range(tiles):
        mem[A_G + i * TILE:A_G + i * TILE + TILE] = a_t[i].tobytes()
        mem[B_G + i * TILE:B_G + i * TILE + TILE] = b_t[i].tobytes()

    await _reset(dut)
    cocotb.start_soon(_dram(dut, mem))

    SA, SB = BARRIER_REGION, BARRIER_REGION + TILE
    await _push(dut, [
        barinit(0, 2), barinit(1, 1), barinit(2, 1),
        # prime: tile 0
        load(0, A_G, SA, TILE), load(0, B_G, SB, TILE), wait(0),
        mma(1, SA, SB, slot=0, accum=0), wait(1),
        # tiles 1..3 via REPEAT(3) over a 5-instruction body, gmem strided
        repeat(tiles - 1, 5),
        load(0, A_G + TILE, SA, TILE, gstep=TILE),
        load(0, B_G + TILE, SB, TILE, gstep=TILE),
        wait(0),
        mma(1, SA, SB, slot=0, accum=1),
        wait(1),
        # epilogue
        store(2, D_G, slot=0, dtype=0), wait(2),
    ])
    for _ in range(8000):
        await RisingEdge(dut.clk)
        if int(dut.idle.value):
            break
    else:
        assert False, "chip never went idle (k-loop)"
    for _ in range(8):
        await RisingEdge(dut.clk)

    # golden: chain all 4 tiles in fp32 (matches HW accumulation order)
    ref = _chain(a_t, b_t)
    got = np.frombuffer(bytes(mem[D_G:D_G + M * N * 4]), dtype="<f4")
    for i in range(M * N):
        assert got[i] == ref.ravel()[i], f"D[{i}] = {got[i]} != {ref.ravel()[i]}"


def _chain(a_t, b_t):
    d = np.zeros((M, N), np.float32)
    for a, b in zip(a_t, b_t):
        af = decode_array(a, "e4m3").astype(np.float32)
        bf = decode_array(b, "e4m3").astype(np.float32)
        for k in range(K):
            d += (af[:, k:k+1] * bf[:, k:k+1].T).astype(np.float32)
    return d
