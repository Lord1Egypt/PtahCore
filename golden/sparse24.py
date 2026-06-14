"""2:4 structured sparsity — golden reference (NVIDIA Sparse-Tensor style).

Sparsity is on operand A along K: in every group of 4 consecutive K
elements, exactly 2 are structurally nonzero. A is stored COMPRESSED —

    a_vals : (M, K/2) fp8   — the 2 kept values per group, in K order
    a_meta : (M, K/4) uint8 — per group, two 2-bit indices (kept positions
                              0..3), packed low-nibble = idx0 | idx1<<2,
                              idx0 < idx1 (ascending)

The dense-equivalent A places each kept value at its metadata position and
zeroes the other two lanes, so a 2:4-sparse matmul is BIT-IDENTICAL to the
dense matmul of the decompressed A:

    C[i,j] = Σ_g Σ_{p in kept(i,g)} decode(a_vals)·decode(B[j, 4g+p])

The hardware win is throughput, not numerics: only K/2 MAC steps run (the
two known-zero lanes per group are skipped) → ~2× — while the RESULT equals
the dense reference, which is exactly what these tests assert.

This is the format + semantics contract that the pymodel and the eventual
RTL sparse-select datapath are verified against. K = MMA_K must be a
multiple of 4 (one 2:4 group = 4 lanes).
"""

import numpy as np

from .matmul_reference import matmul_reference


def _kept_positions(meta_byte: int) -> tuple[int, int]:
    """Decode one group's metadata byte → (idx0, idx1), the kept lanes."""
    return meta_byte & 0b11, (meta_byte >> 2) & 0b11


def pack_meta(idx0: int, idx1: int) -> int:
    """Encode a kept-lane pair (ascending) into one metadata byte."""
    assert 0 <= idx0 < idx1 <= 3, f"kept lanes must be ascending in 0..3: {idx0},{idx1}"
    return (idx0 & 0b11) | ((idx1 & 0b11) << 2)


def decompress(a_vals: np.ndarray, a_meta: np.ndarray, k: int) -> np.ndarray:
    """Compressed (a_vals, a_meta) → dense (M, K) fp8 with zeros in the
    dropped lanes (zero byte = fp8 +0.0 in both formats)."""
    m, half = a_vals.shape
    assert half == k // 2, f"a_vals K/2 {half} != {k // 2}"
    groups = k // 4
    assert a_meta.shape == (m, groups), f"a_meta {a_meta.shape} != {(m, groups)}"
    dense = np.zeros((m, k), dtype=np.uint8)
    for i in range(m):
        for g in range(groups):
            p0, p1 = _kept_positions(int(a_meta[i, g]))
            dense[i, 4 * g + p0] = a_vals[i, 2 * g]
            dense[i, 4 * g + p1] = a_vals[i, 2 * g + 1]
    return dense


def matmul_reference_sparse(a_vals: np.ndarray, a_meta: np.ndarray,
                            b_bytes: np.ndarray, fmt: str = "e4m3") -> np.ndarray:
    """Bit-exact 2:4-sparse matmul == dense matmul of the decompressed A.

    a_vals: (M, K/2) uint8 fp8 ; a_meta: (M, K/4) uint8 ; b_bytes: (N, K)
    Returns (M, N) float32.
    """
    n, k = b_bytes.shape
    dense_a = decompress(a_vals, a_meta, k)
    return matmul_reference(dense_a, b_bytes, fmt)


def compress(a_dense: np.ndarray) -> tuple[np.ndarray, np.ndarray]:
    """Dense (M, K) fp8 with 2:4 structure → (a_vals, a_meta).

    Keeps the 2 lowest-index nonzero lanes per group; asserts the input is
    genuinely 2:4 (at most 2 nonzeros per group of 4) — the encoder's job is
    to honor a structure the data already has, not to prune.
    """
    m, k = a_dense.shape
    assert k % 4 == 0, f"K {k} not a multiple of 4"
    groups = k // 4
    a_vals = np.zeros((m, k // 2), dtype=np.uint8)
    a_meta = np.zeros((m, groups), dtype=np.uint8)
    for i in range(m):
        for g in range(groups):
            lanes = a_dense[i, 4 * g:4 * g + 4]
            nz = [p for p in range(4) if lanes[p] != 0]
            assert len(nz) <= 2, f"row {i} group {g} not 2:4 ({len(nz)} nonzeros)"
            p0, p1 = (nz + [p for p in range(4) if p not in nz])[:2]
            p0, p1 = sorted((p0, p1))
            a_vals[i, 2 * g] = lanes[p0]
            a_vals[i, 2 * g + 1] = lanes[p1]
            a_meta[i, g] = pack_meta(p0, p1)
    return a_vals, a_meta


def random_sparse_a(rng, m: int, k: int, fmt: str = "e4m3") -> np.ndarray:
    """Generate a random dense (M, K) fp8 A with exact 2:4 structure
    (2 nonzero lanes per group of 4), NaN/inf scrubbed to 0."""
    from .fp8 import decode_array
    dense = np.zeros((m, k), dtype=np.uint8)
    for i in range(m):
        for g in range(k // 4):
            keep = rng.choice(4, size=2, replace=False)
            for p in keep:
                # nonzero fp8 byte (avoid 0x00/0x80 zero and NaN/inf)
                while True:
                    v = int(rng.integers(1, 256))
                    if v in (0x80,):
                        continue
                    if np.isfinite(decode_array(np.array([[v]], np.uint8), fmt)[0, 0]) \
                            and decode_array(np.array([[v]], np.uint8), fmt)[0, 0] != 0:
                        break
                dense[i, 4 * g + int(p)] = v
    return dense
