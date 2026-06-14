"""MXFP8 — microscaling reference (OCP MX spec), bit-exact golden model.

PtahCore's MX block is the whole tile: K = MMA_K = 32 is exactly one OCP
microscaling block, so the scales are trivially structured —

    A (M, K) fp8  carries ONE E8M0 scale per row    → M scales  (scale_a[i])
    B (N, K) fp8  carries ONE E8M0 scale per column → N scales  (scale_b[j])

and the MX matmul is

    C[i,j] = 2^( (ea[i]-127) + (eb[j]-127) ) · Σ_k decode(A[i,k])·decode(B[j,k])

The inner sum is exactly today's `matmul_reference` (unchanged), and because
the shared scale is a power of two the scaling is a pure EXPONENT ADD on the
fp32 accumulator — never a multiply. That is why the MX hardware is a tiny
exponent-add+saturate block on the existing drain/store path, not a change to
the 1024 MAC cells. This module is the bit-exact contract that the pymodel
drain and the `mx_scale.sv` RTL are both verified against.

E8M0 scale format (OCP MX): 8-bit, UNSIGNED, value = 2^(X - 127),
X ∈ [0, 254]; X = 255 is the only special and means NaN. There is no zero,
no infinity, no sign — a scale is always a positive power of two (or NaN).

Saturation policy at scale time (matches the HW exponent-field op exactly):
    * E8M0 scale NaN (X=255) on either operand → canonical fp32 qNaN
    * accumulator already ±inf / NaN (exp field 0xFF)  → passed through
    * accumulator zero / subnormal (exp field 0x00)    → flushed to ±0
    * new exponent ≥ 0xFF (overflow)                   → ±inf
    * new exponent ≤ 0    (underflow)                  → ±0
    * otherwise: mantissa unchanged, exponent += delta (exact, no rounding)
"""

import numpy as np

import config
from .matmul_reference import matmul_reference

E8M0_BIAS = config.E8M0_BIAS   # E8M0 value = 2^(X - E8M0_BIAS)
E8M0_NAN = config.E8M0_NAN     # the sole E8M0 special: NaN scale
FP32_QNAN = 0x7FC00000         # canonical quiet NaN we emit on a NaN scale


def _scale_one_bits(bits: int, ea: int, eb: int) -> int:
    """Exact fp32 exponent-field scale by 2^((ea-127)+(eb-127)).

    `bits` is the raw uint32 of the fp32 accumulator; returns the raw uint32
    of the scaled result. This is the literal hardware op — golden, pymodel,
    and mx_scale.sv all implement these exact branches.
    """
    bits &= 0xFFFFFFFF
    ea &= 0xFF
    eb &= 0xFF
    if ea == E8M0_NAN or eb == E8M0_NAN:
        return FP32_QNAN

    sign = bits & 0x80000000
    exp = (bits >> 23) & 0xFF
    mant = bits & 0x7FFFFF

    if exp == 0xFF:          # accumulator inf/nan → passthrough
        return bits
    if exp == 0:             # accumulator zero/subnormal → flush to signed 0
        return sign

    # delta = (ea - 127) + (eb - 127); range [-254, +254]
    new = exp + (ea - E8M0_BIAS) + (eb - E8M0_BIAS)
    if new >= 0xFF:          # overflow
        return sign | 0x7F800000
    if new <= 0:             # underflow
        return sign
    return sign | (new << 23) | mant


def scale_value(x: np.float32, ea: int, eb: int) -> np.float32:
    """Scale one fp32 value by the E8M0 pair (ea, eb). Bit-exact."""
    bits = int(np.float32(x).view(np.uint32))
    return np.uint32(_scale_one_bits(bits, int(ea), int(eb))).view(np.float32)


def scale_matrix(d: np.ndarray, scale_a: np.ndarray,
                 scale_b: np.ndarray) -> np.ndarray:
    """Apply row scales (M) and column scales (N) to a (M, N) fp32 matrix.

    scale_a, scale_b are uint8 E8M0 byte arrays of length M and N.
    """
    d = d.astype(np.float32)
    m, n = d.shape
    assert scale_a.shape[0] == m, f"scale_a len {scale_a.shape[0]} != M {m}"
    assert scale_b.shape[0] == n, f"scale_b len {scale_b.shape[0]} != N {n}"
    bits = d.view(np.uint32)
    out = np.empty_like(bits)
    for i in range(m):
        for j in range(n):
            out[i, j] = _scale_one_bits(int(bits[i, j]),
                                        int(scale_a[i]), int(scale_b[j]))
    return out.view(np.float32).copy()


def matmul_reference_mx(a_bytes: np.ndarray, b_bytes: np.ndarray,
                        scale_a: np.ndarray, scale_b: np.ndarray,
                        fmt: str = "e4m3") -> np.ndarray:
    """Bit-exact MXFP8 matmul (single block: K = MMA_K = one MX block).

    a_bytes: (M, K) uint8 fp8 ; scale_a: (M,) uint8 E8M0 (one per A row)
    b_bytes: (N, K) uint8 fp8 ; scale_b: (N,) uint8 E8M0 (one per B col)
    Returns (M, N) float32 = scale ⊙ (A @ B^T).

    The scale is applied to the slot's accumulator at DRAIN, exactly as the
    hardware does — so MX is a single-block op (accum=0). Accumulating two
    differently-scaled blocks into one slot would scale them by one factor
    at drain, which is not the MX contract; the K-loop accum path is the
    plain (mx=0) mode.
    """
    unscaled = matmul_reference(a_bytes, b_bytes, fmt)     # (M, N) fp32
    return scale_matrix(unscaled, scale_a, scale_b)
