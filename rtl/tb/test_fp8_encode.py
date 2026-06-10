"""cocotb: fp8_encode.sv vs golden.fp8.encode — roundtrip + boundaries."""

import math
import struct
import sys
from pathlib import Path

import cocotb
from cocotb.triggers import Timer
import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))
from golden.fp8 import decode, encode  # noqa: E402


def bits(v) -> int:
    return struct.unpack("<I", struct.pack("<f", float(np.float32(v))))[0]


async def _check(dut, value: float, tag: str):
    value = float(np.float32(value))   # DUT sees fp32 bits — golden must too
    dut.in32.value = bits(value)
    await Timer(1, "ns")
    got = int(dut.out8.value)
    want = encode(value, "e4m3")
    assert got == want, (
        f"{tag}: encode({value}) → {got:#04x}, want {want:#04x} "
        f"(decode(got)={decode(got, 'e4m3')}, decode(want)={decode(want, 'e4m3')})")


@cocotb.test()
async def roundtrip_all_e4m3_values(dut):
    """Every exactly-representable value encodes to itself."""
    for byte in range(256):
        v = decode(byte, "e4m3")
        if math.isnan(v):
            continue
        await _check(dut, v, f"roundtrip {byte:#04x}")


@cocotb.test()
async def rounding_boundaries(dut):
    """Midpoints and near-midpoints across the whole range."""
    vals = []
    for byte in range(0x7E):                  # positive finite codes
        v0 = decode(byte, "e4m3")
        v1 = decode(byte + 1, "e4m3")
        if math.isnan(v1):
            break
        mid = (v0 + v1) / 2
        vals += [mid, math.nextafter(mid, 0), math.nextafter(mid, 1e9)]
    for v in vals:
        await _check(dut, v, "midpoint")
        await _check(dut, -v, "midpoint-neg")


@cocotb.test()
async def saturation_and_specials(dut):
    cases = [449.0, 464.0, 465.0, 1e9, float("inf"),
             -449.0, -464.0, -465.0, -1e9, float("-inf"),
             448.0, -448.0, 0.0, -0.0,
             2.0 ** -9, 2.0 ** -10, 2.0 ** -11,        # min sub, tie, below
             3 * 2.0 ** -11,                           # rounds to min sub
             1e-30, -1e-30]                            # deep underflow → 0
    for v in cases:
        await _check(dut, v, "special")
    # NaN → canonical 0x7F
    dut.in32.value = 0x7FC00000
    await Timer(1, "ns")
    assert int(dut.out8.value) == 0x7F


@cocotb.test()
async def random_sweep(dut):
    rng = np.random.default_rng(31)
    for v in rng.uniform(-500, 500, 2000):
        await _check(dut, float(np.float32(v)), "rand")
    for v in rng.uniform(-0.02, 0.02, 1000):           # subnormal-heavy zone
        await _check(dut, float(np.float32(v)), "rand-small")
