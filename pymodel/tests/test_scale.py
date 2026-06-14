"""Phase 10 — config scalability: the whole design parameterizes.

config.py is the single source of truth for MMA_M/N/K; every model reads it
at runtime. These tests drive the full pymodel (cmdproc → load → array →
store) at shapes OTHER than the native 32×32×32 — including the Phase-10
**64×64** config — and assert bit-exact vs golden. This is the Docker-free
half of "64×64 config build"; the bigger GDS itself is a P&R re-run.
"""

import numpy as np
import pytest

import config
from golden.fp8 import decode_array
from golden.matmul_reference import matmul_reference
from golden.mxfp8 import E8M0_BIAS, matmul_reference_mx
from pymodel.isa import BarInit, Load, Mma, Store, Wait
from pymodel.sim import Sim


@pytest.fixture
def shape(request):
    """Temporarily reshape the design via config (restored after)."""
    m, n, k = request.param
    saved = (config.MMA_M, config.MMA_N, config.MMA_K)
    config.MMA_M, config.MMA_N, config.MMA_K = m, n, k
    yield m, n, k
    config.MMA_M, config.MMA_N, config.MMA_K = saved


def _scrub(rng, rows, k, fmt="e4m3"):
    t = rng.integers(0, 256, (rows, k), dtype=np.uint8)
    t[~np.isfinite(decode_array(t, fmt))] = 0
    return t


@pytest.mark.parametrize("shape", [(16, 16, 16), (64, 64, 64), (64, 32, 16)],
                         indirect=True)
def test_single_tile_matmul_scales(shape):
    m, n, k = shape
    rng = np.random.default_rng(m * 100 + n + k)
    a = _scrub(rng, m, k)
    b = _scrub(rng, n, k)

    sim = Sim()
    A_G, B_G, D_G = 0, 0x20000, 0x40000
    sim.gmem.write(A_G, a.tobytes())
    sim.gmem.write(B_G, b.tobytes())
    SA = config.BARRIER_REGION
    SB = SA + a.nbytes
    sim.push_program([
        BarInit(0, 2), BarInit(1, 1), BarInit(2, 1),
        Load(0, A_G, SA, a.nbytes), Load(0, B_G, SB, b.nbytes), Wait(0),
        Mma(1, SA, SB, slot=0, accum=0), Wait(1),
        Store(2, D_G, slot=0, dtype=0), Wait(2),
    ])
    sim.run()
    raw = sim.gmem.read(D_G, m * n * 4)
    got = np.frombuffer(raw, dtype="<f4").reshape(m, n)
    np.testing.assert_array_equal(got, matmul_reference(a, b, "e4m3"))


@pytest.mark.parametrize("shape", [(64, 64, 64)], indirect=True)
def test_mxfp8_scales_to_64(shape):
    """Phase 8 microscaling holds at the 64×64 config too."""
    m, n, k = shape
    rng = np.random.default_rng(64)
    a = _scrub(rng, m, k)
    b = _scrub(rng, n, k)
    sa = rng.integers(E8M0_BIAS - 6, E8M0_BIAS + 6, m, dtype=np.uint16).astype(np.uint8)
    sb = rng.integers(E8M0_BIAS - 6, E8M0_BIAS + 6, n, dtype=np.uint16).astype(np.uint8)

    sim = Sim()
    A_G, B_G, SA_G, SB_G, D_G = 0, 0x20000, 0x40000, 0x41000, 0x60000
    sim.gmem.write(A_G, a.tobytes()); sim.gmem.write(B_G, b.tobytes())
    sim.gmem.write(SA_G, sa.tobytes()); sim.gmem.write(SB_G, sb.tobytes())
    SA = config.BARRIER_REGION
    SB = SA + a.nbytes
    SSA = SB + b.nbytes
    SSB = SSA + ((m + 15) & ~15)
    sim.push_program([
        BarInit(0, 4), BarInit(1, 1), BarInit(2, 1),
        Load(0, A_G, SA, a.nbytes), Load(0, B_G, SB, b.nbytes),
        Load(0, SA_G, SSA, (m + 15) & ~15), Load(0, SB_G, SSB, (n + 15) & ~15),
        Wait(0),
        Mma(1, SA, SB, slot=0, accum=0, mx=1, sa_smem=SSA, sb_smem=SSB),
        Wait(1), Store(2, D_G, slot=0, dtype=0), Wait(2),
    ])
    sim.run()
    raw = sim.gmem.read(D_G, m * n * 4)
    got = np.frombuffer(raw, dtype="<f4").reshape(m, n)
    np.testing.assert_array_equal(got, matmul_reference_mx(a, b, sa, sb, "e4m3"))
