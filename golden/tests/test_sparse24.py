"""2:4 structured sparsity golden tests — format roundtrip + sparse matmul.

Asserts the compressed (a_vals, a_meta) form reproduces the dense matmul of
the decompressed A exactly, plus the metadata pack/unpack and structure
guards. K = MMA_K = 32 → 8 groups of 4.
"""

import numpy as np
import pytest

import config
from golden.fp8 import decode_array
from golden.matmul_reference import matmul_reference
from golden.sparse24 import (compress, decompress, matmul_reference_sparse,
                             pack_meta, random_sparse_a, _kept_positions)


def _scrub_b(rng, n, k, fmt):
    b = rng.integers(0, 256, (n, k), dtype=np.uint8)
    b[~np.isfinite(decode_array(b, fmt))] = 0
    return b


def test_meta_pack_roundtrip():
    for i0 in range(4):
        for i1 in range(i0 + 1, 4):
            assert _kept_positions(pack_meta(i0, i1)) == (i0, i1)


def test_compress_decompress_roundtrip():
    rng = np.random.default_rng(0)
    m, k = config.MMA_M, config.MMA_K
    dense = random_sparse_a(rng, m, k, "e4m3")
    a_vals, a_meta = compress(dense)
    assert a_vals.shape == (m, k // 2)
    assert a_meta.shape == (m, k // 4)
    np.testing.assert_array_equal(decompress(a_vals, a_meta, k), dense)


def test_exactly_two_nonzeros_per_group():
    rng = np.random.default_rng(1)
    dense = random_sparse_a(rng, config.MMA_M, config.MMA_K, "e4m3")
    for i in range(config.MMA_M):
        for g in range(config.MMA_K // 4):
            assert np.count_nonzero(dense[i, 4 * g:4 * g + 4]) == 2


@pytest.mark.parametrize("fmt", ["e4m3", "e5m2"])
@pytest.mark.parametrize("seed", [0, 1, 2])
def test_sparse_matmul_equals_dense(fmt, seed):
    """The whole point: 2:4-sparse matmul == dense matmul of decompressed A."""
    rng = np.random.default_rng(seed)
    m, n, k = config.MMA_M, config.MMA_N, config.MMA_K
    dense_a = random_sparse_a(rng, m, k, fmt)
    b = _scrub_b(rng, n, k, fmt)

    a_vals, a_meta = compress(dense_a)
    got = matmul_reference_sparse(a_vals, a_meta, b, fmt)
    ref = matmul_reference(dense_a, b, fmt)
    np.testing.assert_array_equal(got, ref)


def test_sparse_matmul_vs_numpy():
    """Cross-check against an independent float64 decompressed dot."""
    rng = np.random.default_rng(7)
    m, n, k = config.MMA_M, config.MMA_N, config.MMA_K
    dense_a = random_sparse_a(rng, m, k, "e4m3")
    b = _scrub_b(rng, n, k, "e4m3")
    a_vals, a_meta = compress(dense_a)

    got = matmul_reference_sparse(a_vals, a_meta, b, "e4m3")
    a64 = decode_array(dense_a, "e4m3").astype(np.float64)
    b64 = decode_array(b, "e4m3").astype(np.float64)
    np.testing.assert_allclose(got, a64 @ b64.T, rtol=5e-5, atol=1e-2)


def test_compress_rejects_non_2of4():
    bad = np.zeros((1, config.MMA_K), dtype=np.uint8)
    bad[0, 0:3] = [1, 2, 3]              # 3 nonzeros in group 0 → invalid
    with pytest.raises(AssertionError):
        compress(bad)


def test_all_same_kept_positions():
    """A degenerate-but-legal pattern: every group keeps lanes {0,1}."""
    rng = np.random.default_rng(9)
    m, n, k = config.MMA_M, config.MMA_N, config.MMA_K
    dense = np.zeros((m, k), dtype=np.uint8)
    vals = rng.integers(1, 120, (m, k // 2), dtype=np.uint8)
    for i in range(m):
        for g in range(k // 4):
            dense[i, 4 * g] = vals[i, 2 * g]
            dense[i, 4 * g + 1] = vals[i, 2 * g + 1]
    b = _scrub_b(rng, n, k, "e4m3")
    a_vals, a_meta = compress(dense)
    assert (a_meta == pack_meta(0, 1)).all()
    np.testing.assert_array_equal(
        matmul_reference_sparse(a_vals, a_meta, b, "e4m3"),
        matmul_reference(dense, b, "e4m3"))
