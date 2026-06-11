"""LOAD / STORE engine tests — bandwidth, tx accounting, async arrival."""

import struct

import numpy as np

import config
from pymodel.barrier import BarrierFile
from pymodel.gmem import Gmem
from pymodel.load import LoadEngine
from pymodel.mac_array import MacArray
from pymodel.smem import Smem
from pymodel.store import StoreEngine


def _rig():
    g, s, b = Gmem(), Smem(), BarrierFile()
    return g, s, b, LoadEngine(g, s, b)


def test_load_moves_bytes_and_arrives():
    g, s, b, ld = _rig()
    payload = bytes(range(256)) * 2          # 512 B
    g.write(4096, payload)
    b.init(0, 1)
    ld.start(0, gmem=4096, smem=config.BARRIER_REGION, nbytes=512)
    assert b.tx[0] == 512                    # issue-time tx
    cycles = 0
    while ld.busy:
        ld.tick()
        cycles += 1
    assert cycles == 512 // config.LOAD_BYTES_PER_CYCLE
    assert s.read(config.BARRIER_REGION, 512) == payload
    assert b.phase(0) == 1                   # arrival flipped the barrier
    assert b.tx[0] == 0


def test_load_rejects_unaligned():
    g, s, b, ld = _rig()
    b.init(0, 1)
    import pytest
    with pytest.raises(AssertionError):
        ld.start(0, 0, config.BARRIER_REGION, nbytes=17)


def test_store_fp32_async_arrival():
    g, s, b = Gmem(), Smem(), BarrierFile()
    arr = MacArray()
    arr.tmem[:, :, 1] = np.arange(
        config.MMA_M * config.MMA_N, dtype=np.float32).reshape(
        config.MMA_M, config.MMA_N)
    st = StoreEngine(g, arr, b)
    b.init(2, 1)
    st.start(2, gmem=8192, slot=1, dtype=0)
    assert st.busy and b.phase(2) == 0       # async: nothing waits
    cycles = 0
    while st.busy:
        st.tick()
        cycles += 1
    elems = config.MMA_M * config.MMA_N
    # 1 elem/cycle + one settle bubble per drain row (ARRAY_SPEC §3)
    assert cycles == elems + config.MMA_M
    assert b.phase(2) == 1                   # arrival on completion
    out = np.frombuffer(g.read(8192, elems * 4), dtype="<f4")
    np.testing.assert_array_equal(out, arr.tmem[:, :, 1].ravel())


def test_store_fp8_conversion():
    g, s, b = Gmem(), Smem(), BarrierFile()
    arr = MacArray()
    arr.tmem[0, 0, 0] = np.float32(1.0)
    arr.tmem[0, 1, 0] = np.float32(-448.0)
    arr.tmem[0, 2, 0] = np.float32(1e9)      # saturates to 448
    st = StoreEngine(g, arr, b)
    b.init(0, 1)
    st.start(0, gmem=0, slot=0, dtype=1)
    while st.busy:
        st.tick()
    out = g.read(0, 3)
    assert out[0] == 0x38                    # 1.0 e4m3
    assert out[1] == 0xFE                    # -448
    assert out[2] == 0x7E                    # +448 (saturated)
