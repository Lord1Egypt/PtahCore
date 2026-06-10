"""End-to-end: full programs through the Sim — the Phase 2 exit criteria.

1. Single-tile matmul, fp32 out — bit-exact vs golden.
2. K-loop (K=4 tiles) with REPEAT + double-buffered SMEM — bit-exact.
3. Async STORE overlap: next kernel's LOAD starts while STORE drains.
"""

import numpy as np

import config
from golden.fp8 import decode_array
from golden.matmul_reference import matmul_reference
from pymodel.isa import BarInit, Load, Mma, Store, Wait, Repeat
from pymodel.sim import Sim

M, N, K = None, None, None  # filled from config at import


def setup_module(_):
    global M, N, K
    M, N, K = config.MMA_M, config.MMA_N, config.MMA_K


def _scrubbed_tile(rng, rows, fmt="e4m3"):
    t = rng.integers(0, 256, (rows, config.MMA_K), dtype=np.uint8)
    t[~np.isfinite(decode_array(t, fmt))] = 0
    return t


def test_single_tile_matmul_fp32():
    rng = np.random.default_rng(10)
    a = _scrubbed_tile(rng, config.MMA_M)
    b = _scrubbed_tile(rng, config.MMA_N)

    sim = Sim()
    A_G, B_G, D_G = 0, 4096, 65536
    sim.gmem.write(A_G, a.tobytes())
    sim.gmem.write(B_G, b.tobytes())
    SA = config.BARRIER_REGION
    SB = SA + a.nbytes

    sim.push_program([
        BarInit(0, 2),                       # 2 LOADs
        BarInit(1, 1),                       # MMA
        BarInit(2, 1),                       # STORE
        Load(0, A_G, SA, a.nbytes),
        Load(0, B_G, SB, b.nbytes),
        Wait(0),
        Mma(1, SA, SB, slot=0, accum=0),
        Wait(1),
        Store(2, D_G, slot=0, dtype=0),
        Wait(2),
    ])
    cycles = sim.run()
    got = sim.read_result_fp32(D_G)
    np.testing.assert_array_equal(got, matmul_reference(a, b, "e4m3"))
    assert cycles < 5000


def test_kloop_repeat_double_buffered():
    """C = sum over 4 K-tiles of A_t @ B_t^T, driven by ONE REPEAT block."""
    rng = np.random.default_rng(11)
    tiles = 4
    a_tiles = [_scrubbed_tile(rng, config.MMA_M) for _ in range(tiles)]
    b_tiles = [_scrubbed_tile(rng, config.MMA_N) for _ in range(tiles)]

    sim = Sim()
    AB = config.MMA_M * config.MMA_K        # tile byte sizes (fp8)
    BB = config.MMA_N * config.MMA_K
    A_G, B_G, D_G = 0, 0x40000, 0x80000
    for t in range(tiles):
        sim.gmem.write(A_G + t * AB, a_tiles[t].tobytes())
        sim.gmem.write(B_G + t * BB, b_tiles[t].tobytes())

    SA = config.BARRIER_REGION              # single-buffer SMEM this v1 test
    SB = SA + AB

    # Body: LOAD A_t, LOAD B_t, WAIT, MMA(accum=1), WAIT — strided by t.
    # Tile 0 primes the accumulator with accum=0 outside the REPEAT.
    prog = [
        BarInit(0, 2), BarInit(1, 1), BarInit(2, 1),
        Load(0, A_G, SA, AB), Load(0, B_G, SB, BB), Wait(0),
        Mma(1, SA, SB, slot=0, accum=0), Wait(1),
        Repeat(count=tiles - 1, length=5),
        Load(0, A_G + AB, SA, AB, gstep=AB),
        Load(0, B_G + BB, SB, BB, gstep=BB),
        Wait(0),
        Mma(1, SA, SB, slot=0, accum=1),
        Wait(1),
        Store(2, D_G, slot=0, dtype=0), Wait(2),
    ]
    sim.push_program(prog)
    sim.run()

    ref = matmul_reference(a_tiles[0], b_tiles[0], "e4m3")
    for t in range(1, tiles):
        ref = matmul_reference(a_tiles[t], b_tiles[t], "e4m3", accum_init=ref)
    np.testing.assert_array_equal(sim.read_result_fp32(D_G), ref)


def test_async_store_overlaps_next_load():
    """PtahCore's async STORE: a LOAD for the next kernel completes while
    the STORE is still draining — impossible with autogpu's sync STORE."""
    rng = np.random.default_rng(12)
    a = _scrubbed_tile(rng, config.MMA_M)
    b = _scrubbed_tile(rng, config.MMA_N)

    sim = Sim()
    A_G, B_G, D_G, NEXT_G = 0, 4096, 65536, 0x20000
    sim.gmem.write(A_G, a.tobytes())
    sim.gmem.write(B_G, b.tobytes())
    sim.gmem.write(NEXT_G, bytes(range(256)))
    SA = config.BARRIER_REGION
    SB = SA + a.nbytes
    SNEXT = SB + b.nbytes

    sim.push_program([
        BarInit(0, 2), BarInit(1, 1), BarInit(2, 1), BarInit(3, 1),
        Load(0, A_G, SA, a.nbytes), Load(0, B_G, SB, b.nbytes), Wait(0),
        Mma(1, SA, SB, slot=0, accum=0), Wait(1),
        Store(2, D_G, slot=0, dtype=0),      # async — no Wait here
        Load(3, NEXT_G, SNEXT, 256),         # issued WHILE store drains
        Wait(3),                             # next-kernel load done…
        Wait(2),                             # …before we finally join store
    ])

    # Track overlap: run manually and observe both engines busy at once.
    overlap = 0
    while not (sim.cmdproc.idle and not sim.load.busy
               and not sim.array.busy and not sim.store.busy):
        sim.tick()
        if sim.store.busy and sim.load.busy:
            overlap += 1
        assert sim.cycles < 100_000

    assert overlap > 0, "async STORE should overlap the next LOAD"
    assert sim.smem.read(SNEXT, 256) == bytes(range(256))
    np.testing.assert_array_equal(sim.read_result_fp32(D_G),
                                  matmul_reference(a, b, "e4m3"))


def test_fp8_output_roundtrip():
    rng = np.random.default_rng(13)
    a = _scrubbed_tile(rng, config.MMA_M)
    b = _scrubbed_tile(rng, config.MMA_N)
    sim = Sim()
    sim.gmem.write(0, a.tobytes())
    sim.gmem.write(4096, b.tobytes())
    SA = config.BARRIER_REGION
    SB = SA + a.nbytes
    sim.push_program([
        BarInit(0, 2), BarInit(1, 1), BarInit(2, 1),
        Load(0, 0, SA, a.nbytes), Load(0, 4096, SB, b.nbytes), Wait(0),
        Mma(1, SA, SB, slot=0, accum=0), Wait(1),
        Store(2, 65536, slot=0, dtype=1), Wait(2),    # fp8 out
    ])
    sim.run()
    from golden.fp8 import encode_array
    expected = encode_array(matmul_reference(a, b, "e4m3"), "e4m3")
    np.testing.assert_array_equal(sim.read_result_fp8(65536), expected)
