"""cocotb: fp32_mul / fp32_add vs numpy float32 — bit-exact.

Operand distribution mirrors real PtahCore traffic:
- mul: decoded fp8 values (every finite e4m3/e5m2 value, plus random pairs)
- add: running fp32 accumulators vs fp8 products (random magnitudes), plus
  directed edge cases (cancellation, carry, signed zeros, inf).
"""

import itertools
import struct
import sys
from pathlib import Path

import cocotb
from cocotb.triggers import Timer
import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))
from golden.fp8 import decode  # noqa: E402


def bits(v) -> int:
    return struct.unpack("<I", struct.pack("<f", float(np.float32(v))))[0]


def val(b: int) -> np.float32:
    return np.frombuffer(struct.pack("<I", b), dtype=np.float32)[0]


def _is_nan_bits(b: int) -> bool:
    return ((b >> 23) & 0xFF) == 0xFF and (b & 0x7FFFFF) != 0


async def _check(dut, a_bits: int, b_bits: int, want_bits: int, tag: str):
    dut.a.value = a_bits
    dut.b.value = b_bits
    await Timer(1, unit="ns")
    got = int(dut.y.value)
    if _is_nan_bits(want_bits):
        assert _is_nan_bits(got), f"{tag}: want NaN got {got:#010x}"
    else:
        assert got == want_bits, (
            f"{tag}: a={a_bits:#010x} b={b_bits:#010x} "
            f"got {got:#010x} want {want_bits:#010x} "
            f"({val(a_bits)} op {val(b_bits)} = {val(want_bits)})")


def _finite_fp8_values():
    out = []
    for byte in range(256):
        for fmt in ("e4m3", "e5m2"):
            v = decode(byte, fmt)
            if np.isfinite(v):
                out.append(np.float32(v))
    return sorted(set(float(v) for v in out))


@cocotb.test()
async def mul_fp8_pairs(dut):
    """All-pairs over a stratified sample of decoded fp8 values."""
    if "mul" not in dut._name:
        return
    vals = _finite_fp8_values()
    sample = vals[::9] + [0.0, 1.0, -1.0, 448.0, -448.0, 57344.0]
    for x, ybit in itertools.product(sample, repeat=2):
        want = np.float32(np.float32(x) * np.float32(ybit))
        await _check(dut, bits(x), bits(ybit), bits(want), "mul")


@cocotb.test()
async def mul_specials(dut):
    if "mul" not in dut._name:
        return
    inf, nan = float("inf"), float("nan")
    cases = [(inf, 2.0), (2.0, -inf), (inf, inf), (inf, 0.0), (0.0, -inf),
             (nan, 1.0), (1.0, nan), (0.0, -0.0), (-0.0, -0.0)]
    for x, z in cases:
        want = np.float32(x) * np.float32(z)
        await _check(dut, bits(x), bits(z), bits(want), "mul-special")


@cocotb.test()
async def add_random_accumulator_traffic(dut):
    if "add" not in dut._name:
        return
    rng = np.random.default_rng(99)
    # accumulators: wide range; addends: fp8-product-like magnitudes
    accs = rng.uniform(-1e5, 1e5, 4000).astype(np.float32)
    prods = (rng.uniform(-448, 448, 4000) * rng.uniform(-448, 448, 4000)
             ).astype(np.float32)
    for x, z in zip(accs, prods):
        want = np.float32(x + z)
        await _check(dut, bits(x), bits(z), bits(want), "add-rand")


@cocotb.test()
async def add_directed_edges(dut):
    if "add" not in dut._name:
        return
    inf, nan = float("inf"), float("nan")
    f = np.float32
    cases = [
        (1.0, 1.0), (1.0, -1.0),                       # exact cancel → +0
        (0.0, -0.0), (-0.0, -0.0), (0.0, 0.0),
        (1.0, 2.0 ** -24), (1.0, 2.0 ** -25),          # round boundary
        (1.0, -(2.0 ** -25)),                          # near-cancel borrow
        (f(3.4e38), f(3.4e38)),                        # overflow → inf
        (16777216.0, 1.0),                             # 2^24 + 1 RNE tie
        (16777216.0, 3.0),
        (-16777216.0, -1.0),
        (inf, 1.0), (1.0, -inf), (inf, -inf),          # inf-inf → NaN
        (nan, 1.0),
        (1.5, 1.5), (1.999999, 1.999999),              # carry path
        (2.0 ** 100, 2.0 ** -100),                     # huge align distance
    ]
    for x, z in cases:
        want = np.float32(f(x) + f(z))
        await _check(dut, bits(x), bits(z), bits(want), f"add-edge({x},{z})")


@cocotb.test()
async def add_sequential_accumulation_chain(dut):
    """Simulate exactly what a MAC slot sees: 32 sequential adds."""
    if "add" not in dut._name:
        return
    rng = np.random.default_rng(7)
    prods = (rng.uniform(-448, 448, 32) * rng.uniform(-1, 1, 32)
             ).astype(np.float32)
    acc = np.float32(0)
    for pval in prods:
        want = np.float32(acc + pval)
        await _check(dut, bits(acc), bits(pval), bits(want), "add-chain")
        acc = want
