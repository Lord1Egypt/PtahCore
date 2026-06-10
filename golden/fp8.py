"""Bit-exact fp8 encode/decode for both OCP formats: e4m3 and e5m2.

This is the golden reference every other layer (pymodel, RTL) is tested
against. Pure stdlib + numpy, no dependencies on ML frameworks.

Format summary (OCP FP8 spec):
    e4m3: 1 sign, 4 exp (bias 7),  3 mantissa. No inf; S.1111.111 = NaN.
          Max normal ±448. Subnormals: exp=0 → 2^-6 * (m/8).
    e5m2: 1 sign, 5 exp (bias 15), 2 mantissa. IEEE-like: has ±inf, NaNs.
          Max normal ±57344. Subnormals: exp=0 → 2^-14 * (m/4).
"""

import numpy as np

_SPECS = {
    "e4m3": dict(exp_bits=4, man_bits=3, bias=7),
    "e5m2": dict(exp_bits=5, man_bits=2, bias=15),
}


def decode(byte: int, fmt: str = "e4m3") -> float:
    """Decode one fp8 byte → Python float (exact)."""
    spec = _SPECS[fmt]
    eb, mb, bias = spec["exp_bits"], spec["man_bits"], spec["bias"]
    byte &= 0xFF
    sign = -1.0 if (byte >> 7) else 1.0
    exp = (byte >> mb) & ((1 << eb) - 1)
    man = byte & ((1 << mb) - 1)

    if fmt == "e4m3":
        # S.1111.111 is the ONLY NaN encoding; 1111 exp with man!=7 is normal
        if exp == 0b1111 and man == 0b111:
            return float("nan")
    else:  # e5m2 — IEEE-like specials
        if exp == 0b11111:
            if man == 0:
                return sign * float("inf")
            return float("nan")

    if exp == 0:  # subnormal (or zero)
        return sign * (man / (1 << mb)) * 2.0 ** (1 - bias)
    return sign * (1 + man / (1 << mb)) * 2.0 ** (exp - bias)


def encode(value: float, fmt: str = "e4m3") -> int:
    """Encode float → nearest fp8 byte (round-to-nearest-even, saturating).

    Saturation policy (matches HW): overflow clamps to max normal, except
    e5m2 ±inf inputs stay ±inf. NaN → canonical NaN encoding.
    """
    spec = _SPECS[fmt]
    eb, mb, bias = spec["exp_bits"], spec["man_bits"], spec["bias"]

    if np.isnan(value):
        return 0x7F if fmt == "e4m3" else 0x7E  # canonical NaN
    sign_bit = 0x80 if (value < 0 or (value == 0 and np.signbit(value))) else 0
    v = abs(float(value))

    if np.isinf(v):
        if fmt == "e5m2":
            return sign_bit | 0x7C  # ±inf
        return sign_bit | 0x7E      # e4m3: saturate to ±448

    if v == 0.0:
        return sign_bit

    # Candidates: every representable magnitude (256 values is tiny — exact
    # nearest-even by exhaustive scan keeps this reference dead simple).
    best = _nearest_code(v, fmt)
    return sign_bit | best


def _all_magnitudes(fmt: str):
    """[(code, value)] for all non-negative finite encodings, ascending."""
    out = []
    for code in range(0x80):
        val = decode(code, fmt)
        if np.isfinite(val):
            out.append((code, val))
    out.sort(key=lambda cv: cv[1])
    return out


_MAG_CACHE = {}


def _nearest_code(v: float, fmt: str) -> int:
    if fmt not in _MAG_CACHE:
        _MAG_CACHE[fmt] = _all_magnitudes(fmt)
    mags = _MAG_CACHE[fmt]
    # saturate
    if v >= mags[-1][1]:
        return mags[-1][0]
    best_code, best_err = 0, float("inf")
    for code, val in mags:
        err = abs(v - val)
        if err < best_err or (err == best_err and _is_even(code)):
            # round-to-nearest, ties to even mantissa
            if err < best_err or (err == best_err and not _is_even(best_code)):
                best_code, best_err = code, err
    return best_code


def _is_even(code: int) -> bool:
    return (code & 1) == 0


def decode_array(buf: np.ndarray, fmt: str = "e4m3") -> np.ndarray:
    """uint8 ndarray → float32 ndarray, elementwise exact decode."""
    flat = np.frombuffer(buf.tobytes(), dtype=np.uint8)
    out = np.array([decode(int(b), fmt) for b in flat], dtype=np.float32)
    return out.reshape(buf.shape)


def encode_array(arr: np.ndarray, fmt: str = "e4m3") -> np.ndarray:
    """float ndarray → uint8 ndarray, elementwise nearest-even encode."""
    flat = arr.astype(np.float64).ravel()
    out = np.array([encode(float(v), fmt) for v in flat], dtype=np.uint8)
    return out.reshape(arr.shape)
