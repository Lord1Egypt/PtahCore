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
import config  # noqa: E402
from golden.fp8 import decode_array  # noqa: E402
from golden.mxfp8 import matmul_reference_mx  # noqa: E402

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
def mma(bar, a, b, slot=0, accum=0, fmt=0, mx=0, sa=0, sb=0, sastep=0, sbstep=0):
    # MXFP8 reuses the MMA-unused g32/n32 fields (+ bit 140), matching cmdproc.sv
    g = (sa & 0xFFFF) | ((sb & 0xFFFF) << 16)
    n = (sastep & 0xFFFF) | ((sbstep & 0xFFFF) << 16)
    w = _pack(OP["MMA"], bar=bar, a16=a, b16=b, g32=g, n32=n,
              slot=slot, accdt=accum, fmt=fmt)
    return w | ((mx & 1) << 140)
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
async def mxfp8_single_tile_fp32(dut):
    """MXFP8 matmul through the whole chip — bit-exact vs the MX golden.

    LOADs bring the A/B tiles AND the M+N E8M0 scale bytes into SMEM; the
    MMA carries mx=1 + the scale bases; the scale is added to the fp32
    exponent at drain in store (mx_scale.sv). mx=1 with unit scales would
    equal the plain path; here the scales are non-trivial."""
    rng = np.random.default_rng(40)
    a = _rand(41, M, "e4m3")
    b = _rand(42, N, "e4m3")
    UNIT = config.E8M0_BIAS
    sa = rng.integers(UNIT - 4, UNIT + 4, M, dtype=np.uint16).astype(np.uint8)
    sb = rng.integers(UNIT - 4, UNIT + 4, N, dtype=np.uint16).astype(np.uint8)

    A_G, B_G, SA_G, SB_G, D_G = 0, 64, 128, 160, 4096
    mem = bytearray(8192)
    mem[A_G:A_G + TILE] = a.tobytes()
    mem[B_G:B_G + TILE] = b.tobytes()
    mem[SA_G:SA_G + M] = sa.tobytes()          # E8M0 row scales (rest 0)
    mem[SB_G:SB_G + N] = sb.tobytes()          # E8M0 col scales

    await _reset(dut)
    cocotb.start_soon(_dram(dut, mem))

    SA, SB = BARRIER_REGION, BARRIER_REGION + TILE
    # Scale bases are read as a single RD_BYTES (32-B) chunk, like operand
    # fetches — 32-B aligned. And LOAD writes whole 32-B lines (smem_phys
    # coalesces two 16-B beats), so the scale DMA is one 32-B line even
    # though only M/N bytes are scales (the rest is don't-care padding).
    SSA = SB + TILE                              # 320, 32-B aligned
    SSB = SSA + 32                               # 352, 32-B aligned
    await _push(dut, [
        barinit(0, 4), barinit(1, 1), barinit(2, 1),
        load(0, A_G, SA, TILE),
        load(0, B_G, SB, TILE),
        load(0, SA_G, SSA, 32),                 # full 32-B line (LOAD contract)
        load(0, SB_G, SSB, 32),
        wait(0),
        mma(1, SA, SB, slot=0, accum=0, mx=1, sa=SSA, sb=SSB),
        wait(1),
        store(2, D_G, slot=0, dtype=0),
        wait(2),
    ])
    for _ in range(4000):
        await RisingEdge(dut.clk)
        if int(dut.idle.value):
            break
    else:
        assert False, "chip never went idle (mxfp8)"
    for _ in range(8):
        await RisingEdge(dut.clk)

    ref = matmul_reference_mx(a, b, sa, sb, "e4m3").ravel()
    got = np.frombuffer(bytes(mem[D_G:D_G + M * N * 4]), dtype="<f4")
    for i in range(M * N):
        assert got[i] == ref[i], f"D[{i}] = {got[i]} != {ref[i]}"


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
