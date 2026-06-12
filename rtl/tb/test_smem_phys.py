"""cocotb: smem_phys.sv — banked 1RW SRAM SMEM behind smem's port contract.

Reference model: flat bytearray. Writes arrive as LOAD-style 16-B beat
pairs (low half then high half of a 32-B line); the line becomes visible
at the high beat's clock edge. Reads are 32-B aligned, registered (data
next cycle). rd_stall in the address cycle means the read was displaced
by a line write into the same bank: the data arriving next cycle is
garbage and the address must be reissued — mma_unit's retry contract.
"""

import random
import sys
from pathlib import Path

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import FallingEdge, ReadOnly, RisingEdge

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))

LINES = 2048
LINE_B = 32
BANK_LINES = 256          # 8 banks of 256 lines, bank = line >> 8
FIRST_LINE = 8            # lines 0-7 = barrier region (write floor)


def bank(line):
    return line // BANK_LINES


async def _reset(dut):
    cocotb.start_soon(Clock(dut.clk, 2, "ns").start())
    dut.rst.value = 1
    dut.wr_en.value = 0
    dut.wr_addr.value = 0
    dut.wr_data.value = 0
    dut.rd_a_addr.value = 0
    dut.rd_b_addr.value = 0
    await RisingEdge(dut.clk)
    await RisingEdge(dut.clk)
    dut.rst.value = 0
    await RisingEdge(dut.clk)


async def write_line(dut, line, data: bytes):
    """LOAD stream order: low beat, then high beat (line commits here)."""
    await FallingEdge(dut.clk)
    dut.wr_en.value = 1
    dut.wr_addr.value = line * LINE_B
    dut.wr_data.value = int.from_bytes(data[:16], "little")
    await RisingEdge(dut.clk)
    await FallingEdge(dut.clk)
    dut.wr_addr.value = line * LINE_B + 16
    dut.wr_data.value = int.from_bytes(data[16:], "little")
    await RisingEdge(dut.clk)
    await FallingEdge(dut.clk)
    dut.wr_en.value = 0


async def read_line(dut, port, line):
    """Retry-on-stall read; returns the 32-B line."""
    addr_sig = getattr(dut, f"rd_{port}_addr")
    data_sig = getattr(dut, f"rd_{port}_data")
    while True:
        await FallingEdge(dut.clk)
        addr_sig.value = line * LINE_B
        await ReadOnly()
        stalled = int(dut.rd_stall.value)
        await RisingEdge(dut.clk)
        await ReadOnly()
        data = int(data_sig.value)
        if not stalled:
            return data.to_bytes(LINE_B, "little")


@cocotb.test()
async def paired_writes_then_reads(dut):
    """Lines across all 8 banks, read back on both ports, bit-exact."""
    rng = random.Random(1)
    ref = {}
    await _reset(dut)
    # two lines per bank, including bank boundaries
    lines = []
    for b in range(8):
        base = b * BANK_LINES
        lines += [max(base, FIRST_LINE), base + BANK_LINES - 1]
    for ln in lines:
        data = rng.randbytes(LINE_B)
        ref[ln] = data
        await write_line(dut, ln, data)
    for ln in lines:
        got_a = await read_line(dut, "a", ln)
        got_b = await read_line(dut, "b", ln)
        assert got_a == ref[ln], f"port A line {ln}"
        assert got_b == ref[ln], f"port B line {ln}"


@cocotb.test()
async def conflict_stalls_and_retries(dut):
    """A line write displaces a same-bank read (stall) but not a
    different-bank read; the retried read returns correct data."""
    rng = random.Random(2)
    await _reset(dut)

    victim = 3 * BANK_LINES + 17        # bank 3
    same_bank = 3 * BANK_LINES + 99     # bank 3, different line
    other_bank = 5 * BANK_LINES + 42    # bank 5
    vdata = rng.randbytes(LINE_B)
    sdata = rng.randbytes(LINE_B)
    odata = rng.randbytes(LINE_B)
    await write_line(dut, same_bank, sdata)
    await write_line(dut, other_bank, odata)

    # low beat of the victim write; reads are unaffected (no line write)
    await FallingEdge(dut.clk)
    dut.wr_en.value = 1
    dut.wr_addr.value = victim * LINE_B
    dut.wr_data.value = int.from_bytes(vdata[:16], "little")
    dut.rd_a_addr.value = same_bank * LINE_B
    dut.rd_b_addr.value = other_bank * LINE_B
    await ReadOnly()
    assert int(dut.rd_stall.value) == 0, "low half-line beat must not stall"
    await RisingEdge(dut.clk)

    # high beat = the line write; port A (same bank) is displaced,
    # port B (other bank) must be serviced concurrently
    await FallingEdge(dut.clk)
    dut.wr_addr.value = victim * LINE_B + 16
    dut.wr_data.value = int.from_bytes(vdata[16:], "little")
    await ReadOnly()
    assert int(dut.rd_stall.value) == 1, "same-bank line write must stall"
    await RisingEdge(dut.clk)
    await FallingEdge(dut.clk)
    dut.wr_en.value = 0
    await ReadOnly()
    assert int(dut.rd_stall.value) == 0
    await RisingEdge(dut.clk)
    await ReadOnly()
    # port B's read was issued in the same cycle as the write and serviced
    got_b = int(dut.rd_b_data.value).to_bytes(LINE_B, "little")
    assert got_b == odata, "different-bank read must survive the line write"

    # retried port A read + the freshly written victim line
    assert await read_line(dut, "a", same_bank) == sdata
    assert await read_line(dut, "a", victim) == vdata
    assert await read_line(dut, "b", victim) == vdata


@cocotb.test()
async def random_soak(dut):
    """Interleaved write bursts and dual-port reads with the retry
    protocol, bit-exact vs the reference for 2000 cycles."""
    rng = random.Random(3)
    ref = bytearray(LINES * LINE_B)
    await _reset(dut)

    # pre-write the read pool so reads never depend on power-on state
    pool = sorted(rng.sample(range(FIRST_LINE, LINES), 64))
    for ln in pool:
        data = rng.randbytes(LINE_B)
        ref[ln * LINE_B:(ln + 1) * LINE_B] = data
        await write_line(dut, ln, data)

    burst = []          # remaining (addr, 16B) beats of the current burst
    pend_lo = b""

    for _ in range(2000):
        await FallingEdge(dut.clk)
        if not burst and rng.random() < 0.3:
            ln0 = rng.choice(pool)
            for ln in range(ln0, min(ln0 + rng.randint(1, 3), LINES)):
                d = rng.randbytes(LINE_B)
                burst.append((ln * LINE_B, d[:16]))
                burst.append((ln * LINE_B + 16, d[16:]))
        beat = None
        if burst:
            beat = burst.pop(0)
            dut.wr_en.value = 1
            dut.wr_addr.value = beat[0]
            dut.wr_data.value = int.from_bytes(beat[1], "little")
        else:
            dut.wr_en.value = 0
        la, lb = rng.choice(pool), rng.choice(pool)
        dut.rd_a_addr.value = la * LINE_B
        dut.rd_b_addr.value = lb * LINE_B
        await ReadOnly()
        stalled = int(dut.rd_stall.value)
        await RisingEdge(dut.clk)
        await ReadOnly()
        # the registered outputs latched THIS cycle's reads at the edge,
        # from mem BEFORE this edge's write — which ref also hasn't
        # applied yet (same-line/same-bank races are excluded by stall)
        if not stalled:
            for port, line in (("a", la), ("b", lb)):
                got = int(getattr(dut, f"rd_{port}_data").value)
                want = bytes(ref[line * LINE_B:(line + 1) * LINE_B])
                assert got.to_bytes(LINE_B, "little") == want, \
                    f"port {port} line {line}"
        if beat is not None:
            if beat[0] & 16:  # high beat: line commits at this edge
                line0 = beat[0] & ~31
                ref[line0:line0 + 16] = pend_lo
                ref[line0 + 16:line0 + 32] = beat[1]
            else:
                pend_lo = beat[1]
