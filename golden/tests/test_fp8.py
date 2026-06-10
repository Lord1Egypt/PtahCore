"""Exhaustive + property tests for the fp8 golden model."""

import math

import numpy as np
import pytest

from golden.fp8 import decode, encode, decode_array, encode_array


@pytest.mark.parametrize("fmt", ["e4m3", "e5m2"])
def test_roundtrip_all_256(fmt):
    """encode(decode(b)) == b for every finite, non-NaN byte (canonical zero/NaN aside)."""
    for byte in range(256):
        val = decode(byte, fmt)
        if math.isnan(val):
            continue  # NaN encodes to canonical NaN, not necessarily `byte`
        re = encode(val, fmt)
        # -0.0 and +0.0 both legal; compare decoded values instead of bits
        assert decode(re, fmt) == val or (val == 0 and decode(re, fmt) == 0), (
            f"{fmt} byte {byte:#04x}: decode={val} re-encode={re:#04x}"
        )


def test_e4m3_known_values():
    assert decode(0x00, "e4m3") == 0.0
    assert decode(0x38, "e4m3") == 1.0          # exp=7(bias) man=0
    assert decode(0x7E, "e4m3") == 448.0        # max normal
    assert math.isnan(decode(0x7F, "e4m3"))     # only NaN
    assert decode(0x01, "e4m3") == 2.0 ** -9    # smallest subnormal
    assert decode(0xB8, "e4m3") == -1.0


def test_e5m2_known_values():
    assert decode(0x3C, "e5m2") == 1.0          # exp=15(bias) man=0
    assert decode(0x7B, "e5m2") == 57344.0      # max normal
    assert decode(0x7C, "e5m2") == float("inf")
    assert math.isnan(decode(0x7E, "e5m2"))
    assert decode(0x01, "e5m2") == 2.0 ** -16   # smallest subnormal


@pytest.mark.parametrize("fmt", ["e4m3", "e5m2"])
def test_saturation(fmt):
    max_val = 448.0 if fmt == "e4m3" else 57344.0
    assert decode(encode(1e9, fmt), fmt) == max_val
    assert decode(encode(-1e9, fmt), fmt) == -max_val


def test_e4m3_inf_saturates_e5m2_inf_stays():
    assert decode(encode(float("inf"), "e4m3"), "e4m3") == 448.0
    assert decode(encode(float("inf"), "e5m2"), "e5m2") == float("inf")


@pytest.mark.parametrize("fmt", ["e4m3", "e5m2"])
def test_nan_encodes_to_nan(fmt):
    assert math.isnan(decode(encode(float("nan"), fmt), fmt))


@pytest.mark.parametrize("fmt,max_rel", [("e4m3", 0.07), ("e5m2", 0.14)])
def test_nearest_rounding(fmt, max_rel):
    """Nearest-rounding error bounded by half-ULP: 2^-(mantissa_bits+1) rel,
    doubled at power-of-two boundaries → 0.0625/0.125 worst case + slack."""
    rng = np.random.default_rng(42)
    for v in rng.uniform(-400, 400, size=200):
        code = encode(float(v), fmt)
        got = decode(code, fmt)
        if v != 0:
            assert abs(got - v) <= max(abs(v) * max_rel + 1e-6, 0.02), (fmt, v, got)


def test_array_helpers_shape_and_dtype():
    a = np.array([[1.0, -2.0], [0.5, 448.0]])
    enc = encode_array(a, "e4m3")
    assert enc.dtype == np.uint8 and enc.shape == a.shape
    dec = decode_array(enc, "e4m3")
    assert dec.dtype == np.float32
    np.testing.assert_array_equal(dec, a.astype(np.float32))
