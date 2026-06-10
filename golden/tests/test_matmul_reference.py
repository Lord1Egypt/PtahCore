"""Property tests: golden matmul vs numpy float64 ground truth."""

import numpy as np
import pytest

import config
from golden.fp8 import decode_array, encode_array
from golden.matmul_reference import matmul_reference


@pytest.mark.parametrize("fmt", ["e4m3", "e5m2"])
@pytest.mark.parametrize("seed", [0, 1, 2])
def test_random_matmul_vs_numpy(fmt, seed):
    rng = np.random.default_rng(seed)
    m, n, k = config.MMA_M, config.MMA_N, config.MMA_K

    a_bytes = rng.integers(0, 256, size=(m, k), dtype=np.uint8)
    b_bytes = rng.integers(0, 256, size=(n, k), dtype=np.uint8)
    # scrub NaN/inf encodings for a clean numeric comparison
    a_bytes = _scrub(a_bytes, fmt)
    b_bytes = _scrub(b_bytes, fmt)

    d = matmul_reference(a_bytes, b_bytes, fmt)

    a64 = decode_array(a_bytes, fmt).astype(np.float64)
    b64 = decode_array(b_bytes, fmt).astype(np.float64)
    truth = a64 @ b64.T

    # fp32 sequential accumulation of K=32 products: rounding accrues per
    # step, so allow a few fp32 ULPs of relative drift vs float64 truth.
    np.testing.assert_allclose(d, truth, rtol=5e-5, atol=1e-2)


def test_accumulate_mode():
    """accum=1: result adds onto existing accumulators."""
    rng = np.random.default_rng(7)
    m, n, k = config.MMA_M, config.MMA_N, config.MMA_K
    a = _scrub(rng.integers(0, 256, (m, k), dtype=np.uint8), "e4m3")
    b = _scrub(rng.integers(0, 256, (n, k), dtype=np.uint8), "e4m3")

    once = matmul_reference(a, b, "e4m3")
    twice = matmul_reference(a, b, "e4m3", accum_init=once)
    # Second pass rounds each step against a larger running value, so the
    # result is close to — not bit-identical to — 2×once.
    np.testing.assert_allclose(twice, 2 * once, rtol=5e-5, atol=1e-2)


def test_identity_small():
    """A @ I^T == A decoded, exactly."""
    k = config.MMA_K
    eye_f = np.eye(config.MMA_N, k, dtype=np.float64)
    b = encode_array(eye_f, "e4m3")            # identity is exactly encodable
    rng = np.random.default_rng(3)
    a = _scrub(rng.integers(0, 256, (config.MMA_M, k), dtype=np.uint8), "e4m3")

    d = matmul_reference(a, b, "e4m3")
    np.testing.assert_array_equal(d, decode_array(a, "e4m3")[:, :config.MMA_N])


def _scrub(bytes_arr, fmt):
    """Replace NaN/inf encodings with 0x00 so comparisons stay finite."""
    vals = decode_array(bytes_arr, fmt)
    bad = ~np.isfinite(vals)
    out = bytes_arr.copy()
    out[bad] = 0
    return out
