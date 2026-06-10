"""Golden matmul: fp8 operands → fp32 accumulate, bit-exact reference.

D = A @ B^T  with A: (M, K) fp8, B: (N, K) fp8, D: (M, N) fp32.

B is stored row-major as (N, K) and used transposed — matching the
hardware's broadcast dataflow where each MAC cell (i, j) consumes
A[i, k] and B[j, k] on K-step k.

Accumulation order is sequential over k (0..K-1) in fp32, exactly like
the RTL's per-cell accumulator — NOT numpy's reordered/fused dot. For
fp8 inputs the products are exact in fp32, so the sequential sum equals
numpy's float64 dot rounded per-step; tests assert against this model,
and against numpy within tolerance as a sanity cross-check.
"""

import numpy as np

from .fp8 import decode_array


def matmul_reference(a_bytes: np.ndarray, b_bytes: np.ndarray,
                     fmt: str = "e4m3", accum_init: np.ndarray | None = None
                     ) -> np.ndarray:
    """Bit-exact model of the MAC array.

    a_bytes: (M, K) uint8 fp8
    b_bytes: (N, K) uint8 fp8
    accum_init: optional (M, N) float32 starting accumulators (accum=1 mode)
    returns: (M, N) float32
    """
    a = decode_array(a_bytes, fmt)          # (M, K) float32
    b = decode_array(b_bytes, fmt)          # (N, K) float32
    m, k = a.shape
    n, kb = b.shape
    assert k == kb, f"K mismatch: {k} vs {kb}"

    d = (np.zeros((m, n), dtype=np.float32) if accum_init is None
         else accum_init.astype(np.float32).copy())

    # Sequential K-loop in fp32 — mirrors per-cell RTL accumulation order.
    for kk in range(k):
        # outer product of column kk, accumulated in fp32
        d += np.float32(1) * (a[:, kk:kk + 1] * b[:, kk:kk + 1].T).astype(np.float32)
    return d
