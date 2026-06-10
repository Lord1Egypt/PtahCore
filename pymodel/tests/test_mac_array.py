"""MacArray vs golden matmul_reference — bit-exact."""

import numpy as np
import pytest

import config
from golden.matmul_reference import matmul_reference
from pymodel.mac_array import MacArray


def _rand_tiles(seed, fmt="e4m3"):
    from golden.fp8 import decode_array
    rng = np.random.default_rng(seed)
    a = rng.integers(0, 256, (config.MMA_M, config.MMA_K), dtype=np.uint8)
    b = rng.integers(0, 256, (config.MMA_N, config.MMA_K), dtype=np.uint8)
    for t in (a, b):                       # scrub non-finite encodings
        t[~np.isfinite(decode_array(t, fmt))] = 0
    return a, b


@pytest.mark.parametrize("fmt", ["e4m3", "e5m2"])
def test_single_mma_bit_exact(fmt):
    a, b = _rand_tiles(0, fmt)
    arr = MacArray()
    arr.start(a, b, slot=0, accum=0, fmt=fmt)
    cycles = 0
    while arr.busy:
        arr.tick()
        cycles += 1
    assert cycles == config.MMA_K          # one K-step per cycle
    assert arr.done is True
    np.testing.assert_array_equal(arr.tmem[:, :, 0],
                                  matmul_reference(a, b, fmt))


def test_accumulate_chains_bit_exact():
    """Two MMAs accum=0 then accum=1 == golden chained reference."""
    a0, b0 = _rand_tiles(1)
    a1, b1 = _rand_tiles(2)
    arr = MacArray()
    for a, b, acc in [(a0, b0, 0), (a1, b1, 1)]:
        arr.start(a, b, slot=2, accum=acc, fmt="e4m3")
        while arr.busy:
            arr.tick()
    ref = matmul_reference(a1, b1, "e4m3",
                           accum_init=matmul_reference(a0, b0, "e4m3"))
    np.testing.assert_array_equal(arr.tmem[:, :, 2], ref)


def test_slots_are_independent():
    a, b = _rand_tiles(3)
    arr = MacArray()
    arr.start(a, b, 0, 0, "e4m3")
    while arr.busy:
        arr.tick()
    before = arr.tmem[:, :, 0].copy()
    arr.start(a, b, 1, 0, "e4m3")          # different slot
    while arr.busy:
        arr.tick()
    np.testing.assert_array_equal(arr.tmem[:, :, 0], before)


def test_drain_read_row_major():
    a, b = _rand_tiles(4)
    arr = MacArray()
    arr.start(a, b, 0, 0, "e4m3")
    while arr.busy:
        arr.tick()
    flat = arr.tmem[:, :, 0].ravel()
    for idx in [0, 1, config.MMA_N, config.MMA_M * config.MMA_N - 1]:
        assert arr.drain_read(0, idx) == flat[idx]
