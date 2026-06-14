"""MXFP8 golden reference tests — exact exponent-field scaling + matmul.

Covers every scale edge the hardware exponent-add+saturate block must hit:
unit scale, max/min E8M0 exponent, overflow→±inf, underflow→±0, the NaN
scale (X=255), the zero/inf accumulator passthroughs, and a full random
MXFP8 matmul cross-checked against an independent float64 ground truth.
"""

import numpy as np
import pytest

import config
from golden.fp8 import decode_array, encode_array
from golden.matmul_reference import matmul_reference
from golden.mxfp8 import (E8M0_BIAS, E8M0_NAN, matmul_reference_mx,
                          scale_matrix, scale_value)

UNIT = E8M0_BIAS          # E8M0 byte whose value is 2^0 = 1.0


def test_unit_scale_is_identity():
    """(ea, eb) = (127, 127) → 2^0 · 2^0 = 1: value unchanged, bit-exact."""
    for v in [0.0, -0.0, 1.0, -3.5, 1234.5, 1e-20, -7e18, np.float32(np.pi)]:
        got = scale_value(np.float32(v), UNIT, UNIT)
        assert got.view(np.uint32) == np.float32(v).view(np.uint32)


@pytest.mark.parametrize("da", [-5, -1, 0, 1, 3, 10])
@pytest.mark.parametrize("db", [-7, -2, 0, 2, 6])
def test_inrange_matches_ldexp(da, db):
    """In-range scaling equals an exact power-of-two multiply (np.ldexp)."""
    rng = np.random.default_rng((da + 16) * 31 + (db + 16))
    vals = rng.uniform(-100, 100, size=64).astype(np.float32)
    ea, eb = UNIT + da, UNIT + db
    for v in vals:
        got = scale_value(v, ea, eb)
        ref = np.ldexp(np.float64(v), da + db).astype(np.float32)
        # exponent stays well within [1, 254] for these magnitudes
        assert got.view(np.uint32) == ref.view(np.uint32), (v, da, db)


def test_overflow_saturates_to_signed_inf():
    big = np.float32(3.0e38)               # exp field near the top
    got_pos = scale_value(big, UNIT, UNIT + 30)
    got_neg = scale_value(-big, UNIT + 30, UNIT)
    assert np.isinf(got_pos) and got_pos > 0
    assert np.isinf(got_neg) and got_neg < 0


def test_underflow_flushes_to_signed_zero():
    small = np.float32(1.5e-38)            # exp field near the bottom
    got_pos = scale_value(small, UNIT - 20, UNIT)
    got_neg = scale_value(-small, UNIT, UNIT - 20)
    assert got_pos.view(np.uint32) == np.float32(0.0).view(np.uint32)      # +0
    assert got_neg.view(np.uint32) == np.float32(-0.0).view(np.uint32)     # -0


def test_max_and_min_e8m0_exponents():
    """X=254 → 2^127 (max finite scale); X=0 → 2^-127 (min)."""
    # 2^127 · 1.0 overflows fp32 (max ~2^128) only when combined; check the
    # extremes resolve to inf / zero deterministically.
    assert np.isinf(scale_value(np.float32(1.0), 254, 254))   # 2^254 → inf
    assert scale_value(np.float32(1.0), 0, 0).view(np.uint32) == 0  # 2^-254 → 0
    # a single max-scale on a small value stays finite and exact
    v = np.float32(2.0 ** -100)
    got = scale_value(v, 254, UNIT)        # 2^127 · 2^-100 = 2^27
    assert got == np.float32(2.0 ** 27)


def test_nan_scale_yields_nan():
    assert np.isnan(scale_value(np.float32(1.0), E8M0_NAN, UNIT))
    assert np.isnan(scale_value(np.float32(1.0), UNIT, E8M0_NAN))
    assert np.isnan(scale_value(np.float32(-3.0), E8M0_NAN, E8M0_NAN))


def test_zero_accumulator_passthrough():
    """Zero input stays zero for any finite scale (sign preserved)."""
    assert scale_value(np.float32(0.0), UNIT + 50, UNIT - 9).view(np.uint32) == 0
    nz = scale_value(np.float32(-0.0), UNIT + 3, UNIT)
    assert nz.view(np.uint32) == np.float32(-0.0).view(np.uint32)


def test_inf_nan_accumulator_passthrough():
    """A non-NaN scale leaves an inf/NaN accumulator untouched."""
    assert np.isinf(scale_value(np.float32(np.inf), UNIT, UNIT - 5))
    assert np.isnan(scale_value(np.float32(np.nan), UNIT + 2, UNIT))


@pytest.mark.parametrize("fmt", ["e4m3", "e5m2"])
@pytest.mark.parametrize("seed", [0, 1, 2])
def test_random_mxfp8_matmul_vs_numpy(fmt, seed):
    """Full MXFP8 matmul == float64 (decode·scale·matmul) within fp32 ULPs."""
    rng = np.random.default_rng(seed)
    m, n, k = config.MMA_M, config.MMA_N, config.MMA_K

    a = _scrub(rng.integers(0, 256, (m, k), dtype=np.uint8), fmt)
    b = _scrub(rng.integers(0, 256, (n, k), dtype=np.uint8), fmt)
    # modest scales so the result stays in fp32 range (exponents near unity)
    sa = rng.integers(UNIT - 8, UNIT + 8, size=m, dtype=np.uint16).astype(np.uint8)
    sb = rng.integers(UNIT - 8, UNIT + 8, size=n, dtype=np.uint16).astype(np.uint8)

    d = matmul_reference_mx(a, b, sa, sb, fmt)

    a64 = decode_array(a, fmt).astype(np.float64)
    b64 = decode_array(b, fmt).astype(np.float64)
    fa = np.ldexp(np.ones(m), sa.astype(np.int32) - E8M0_BIAS)   # 2^(ea-127)
    fb = np.ldexp(np.ones(n), sb.astype(np.int32) - E8M0_BIAS)
    truth = (a64 @ b64.T) * np.outer(fa, fb)

    np.testing.assert_allclose(d, truth, rtol=5e-5, atol=1e-2)


def test_mx_unit_scale_equals_plain_matmul():
    """All-unit scales (X=127) must reproduce the plain fp8 matmul exactly."""
    rng = np.random.default_rng(99)
    m, n, k = config.MMA_M, config.MMA_N, config.MMA_K
    a = _scrub(rng.integers(0, 256, (m, k), dtype=np.uint8), "e4m3")
    b = _scrub(rng.integers(0, 256, (n, k), dtype=np.uint8), "e4m3")
    sa = np.full(m, UNIT, dtype=np.uint8)
    sb = np.full(n, UNIT, dtype=np.uint8)
    np.testing.assert_array_equal(matmul_reference_mx(a, b, sa, sb, "e4m3"),
                                  matmul_reference(a, b, "e4m3"))


def test_scale_matrix_shape_guard():
    d = np.zeros((config.MMA_M, config.MMA_N), dtype=np.float32)
    with pytest.raises(AssertionError):
        scale_matrix(d, np.zeros(3, np.uint8), np.full(config.MMA_N, UNIT, np.uint8))


def _scrub(bytes_arr, fmt):
    """Replace NaN/inf fp8 encodings with 0x00 so the matmul stays finite."""
    vals = decode_array(bytes_arr, fmt)
    out = bytes_arr.copy()
    out[~np.isfinite(vals)] = 0
    return out
