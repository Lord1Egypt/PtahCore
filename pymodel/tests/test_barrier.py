"""BarrierFile unit tests — flip rule, tx accounting, phase semantics."""

import pytest

from pymodel.barrier import BarrierFile


def test_flip_on_pending_zero():
    b = BarrierFile()
    b.init(0, 2)
    assert b.phase(0) == 0
    b.arrive(0)
    assert b.phase(0) == 0          # 1 pending left
    b.arrive(0)
    assert b.phase(0) == 1          # flipped
    assert b.pending[0] == 2        # reloaded


def test_tx_blocks_flip():
    b = BarrierFile()
    b.init(1, 1)
    b.add_tx(1, 64)
    b.arrive(1, tx_done=32)         # pending 0 but 32 tx bytes outstanding
    assert b.phase(1) == 0
    b.tx[1] -= 32                   # model the rest landing
    b._maybe_flip(1)
    assert b.phase(1) == 1


def test_two_phase_cycle():
    b = BarrierFile()
    b.init(2, 1)
    b.arrive(2)
    assert b.phase(2) == 1
    b.arrive(2)
    assert b.phase(2) == 0          # flips back


def test_tx_underflow_asserts():
    b = BarrierFile()
    b.init(3, 2)
    with pytest.raises(AssertionError):
        b.arrive(3, tx_done=16)     # tx is 0 — subtracting must trip
