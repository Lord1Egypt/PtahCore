"""cocotb: fp8_decode.sv vs golden.fp8.decode — exhaustive, both formats."""

import math
import struct
import sys
from pathlib import Path

import cocotb
from cocotb.triggers import Timer

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))
from golden.fp8 import decode  # noqa: E402


def f32_bits(v: float) -> int:
    return struct.unpack("<I", struct.pack("<f", v))[0]


@cocotb.test()
async def exhaustive_both_formats(dut):
    for fmt_bit, fmt in [(0, "e4m3"), (1, "e5m2")]:
        dut.fmt.value = fmt_bit
        for byte in range(256):
            dut.in8.value = byte
            await Timer(1, "ns")
            got = int(dut.out.value)
            want = decode(byte, fmt)
            if math.isnan(want):
                # any NaN encoding acceptable: exp=FF, man!=0
                assert (got >> 23) & 0xFF == 0xFF and (got & 0x7FFFFF) != 0, (
                    f"{fmt} {byte:#04x}: expected NaN, got {got:#010x}")
            else:
                assert got == f32_bits(want), (
                    f"{fmt} {byte:#04x}: got {got:#010x} "
                    f"want {f32_bits(want):#010x} ({want})")
