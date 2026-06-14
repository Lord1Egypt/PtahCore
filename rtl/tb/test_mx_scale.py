"""cocotb: mx_scale.sv — the MXFP8 drain-time exponent-add + saturate block,
bit-exact vs the golden reference (golden/mxfp8._scale_one_bits).

Combinational: drive in32/ea/eb/en, settle, compare out32. Covers the
passthrough (en=0), the NaN scale, zero/inf accumulator passthroughs, and
overflow/underflow saturation — the same edges as the golden suite.
"""

import struct
import sys
from pathlib import Path

import cocotb
from cocotb.triggers import Timer
import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))
import config  # noqa: E402
from golden.mxfp8 import _scale_one_bits  # noqa: E402

UNIT = config.E8M0_BIAS


def _bits(v):
    return struct.unpack("<I", struct.pack("<f", float(np.float32(v))))[0]


async def _check(dut, in_bits, ea, eb, en):
    dut.in32.value = in_bits
    dut.ea.value = ea
    dut.eb.value = eb
    dut.en.value = en
    await Timer(1, "ns")
    got = int(dut.out32.value)
    want = _scale_one_bits(in_bits, ea, eb) if en else (in_bits & 0xFFFFFFFF)
    assert got == want, (
        f"in={in_bits:#010x} ea={ea} eb={eb} en={en}: "
        f"got {got:#010x} want {want:#010x}")


@cocotb.test()
async def passthrough_when_disabled(dut):
    rng = np.random.default_rng(1)
    for _ in range(200):
        b = int(rng.integers(0, 1 << 32, dtype=np.uint64))
        ea = int(rng.integers(0, 256))
        eb = int(rng.integers(0, 256))
        await _check(dut, b, ea, eb, 0)


@cocotb.test()
async def random_inrange(dut):
    """Random finite values × modest scales — the common, exact case."""
    rng = np.random.default_rng(2)
    for _ in range(500):
        v = np.float32(rng.uniform(-1e3, 1e3))
        ea = int(rng.integers(UNIT - 10, UNIT + 10))
        eb = int(rng.integers(UNIT - 10, UNIT + 10))
        await _check(dut, _bits(v), ea, eb, 1)


@cocotb.test()
async def scale_edges(dut):
    """NaN scale, zero/inf/NaN accumulator, overflow, underflow, extremes."""
    cases = [
        # (value bits, ea, eb)
        (_bits(0.0),    UNIT + 40, UNIT - 9),     # +0 passthrough
        (_bits(-0.0),   UNIT + 3,  UNIT),         # -0 passthrough
        (_bits(1.0),    UNIT, UNIT),              # unit scale
        (_bits(1.0),    255,  UNIT),              # E8M0 NaN scale → qNaN
        (_bits(-3.0),   UNIT, 255),               # E8M0 NaN scale → qNaN
        (_bits(np.inf), UNIT, UNIT - 5),          # inf accumulator passthrough
        (_bits(np.nan), UNIT + 2, UNIT),          # NaN accumulator passthrough
        (_bits(3.0e38), UNIT, UNIT + 30),         # overflow → +inf
        (_bits(-3.0e38), UNIT + 30, UNIT),        # overflow → -inf
        (_bits(1.5e-38), UNIT - 20, UNIT),        # underflow → +0
        (_bits(-1.5e-38), UNIT, UNIT - 20),       # underflow → -0
        (_bits(1.0),    254, 254),                # 2^254 → inf
        (_bits(1.0),    0,   0),                  # 2^-254 → 0
        (_bits(2.0 ** -100), 254, UNIT),          # 2^127·2^-100 = 2^27 exact
    ]
    for b, ea, eb in cases:
        await _check(dut, b, ea, eb, 1)


@cocotb.test()
async def exhaustive_unit_value_scale_sweep(dut):
    """Sweep both E8M0 bytes over a representative grid on a fixed value."""
    rng = np.random.default_rng(3)
    vals = [np.float32(v) for v in rng.uniform(-50, 50, 8)]
    for v in vals:
        for ea in range(110, 145, 3):
            for eb in range(110, 145, 3):
                await _check(dut, _bits(v), ea, eb, 1)
