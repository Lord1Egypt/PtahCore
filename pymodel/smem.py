"""smem — on-chip operand scratchpad.

INPUTS (method calls)
    read(off, n)   -> bytes
    write(off, data)

INTERNAL STATE
    mem : bytearray(SMEM_BYTES)

BEHAVIOR
    1. Byte-addressed within the SMEM space. 1-cycle read/write modeled
       by callers.
    2. First BARRIER_REGION bytes are reserved for mbarrier objects —
       the BarrierFile owns that range logically; operand tiles must
       live at offsets >= BARRIER_REGION.

INVARIANTS
    - Out-of-range access raises.
    - Engines never write the barrier region (asserted here).
"""

import config


class Smem:
    def __init__(self):
        self.mem = bytearray(config.SMEM_BYTES)

    def read(self, off: int, n: int) -> bytes:
        assert 0 <= off and off + n <= config.SMEM_BYTES, f"smem read OOB: {off}+{n}"
        return bytes(self.mem[off:off + n])

    def write(self, off: int, data: bytes):
        assert off >= config.BARRIER_REGION, (
            f"smem write into barrier region: {off} < {config.BARRIER_REGION}")
        assert off + len(data) <= config.SMEM_BYTES, f"smem write OOB: {off}"
        self.mem[off:off + len(data)] = data
