"""gmem — behavioral off-chip DRAM model.

INPUTS (method calls)
    read(addr, n)    -> bytes
    write(addr, data)

INTERNAL STATE
    mem : bytearray(size)

BEHAVIOR
    1. Byte-addressed, flat. 1-cycle latency is modeled by the engines
       (they self-limit bandwidth); gmem itself is a passive array.

INVARIANTS
    - Out-of-range access raises (catches address bugs at model time).
"""


class Gmem:
    def __init__(self, size: int = 16 * 1024 * 1024):
        self.size = size
        self.mem = bytearray(size)

    def read(self, addr: int, n: int) -> bytes:
        assert 0 <= addr and addr + n <= self.size, f"gmem read OOB: {addr}+{n}"
        return bytes(self.mem[addr:addr + n])

    def write(self, addr: int, data: bytes):
        assert 0 <= addr and addr + len(data) <= self.size, f"gmem write OOB: {addr}"
        self.mem[addr:addr + len(data)] = data
