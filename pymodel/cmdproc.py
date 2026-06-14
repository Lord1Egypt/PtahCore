"""cmdproc — instruction FIFO + decode/dispatch front-end.

INPUTS
    push(instr)          — host/TB side: enqueue (respects FIFO depth)
    tick()               — advance one cycle

OUTPUTS
    idle : bool          — FIFO empty, no REPEAT in flight, nothing stalled

INTERNAL STATE
    fifo            : deque of instructions (CMD_FIFO_DEPTH max)
    phase_tracker   : NUM_BARRIERS bits — expected phase per barrier (WAIT auto-phase)
    repeat state    : body buffer, iteration counter

BEHAVIOR (per tick — at most ONE instruction leaves the front-end)
    1. If stalled on WAIT: re-check barrier phase; unstall + toggle
       tracker when it flips. Nothing else issues this cycle.
    2. Else take next instruction (from REPEAT replay buffer if active,
       else pop FIFO):
       - BarInit: apply immediately; reset phase tracker bit.
       - Load/Mma/Store: if target engine busy → stall (retry next
         cycle); else apply per-iteration strides and fire-and-forget.
       - Wait: if barrier already flipped → consume + toggle tracker;
         else enter WAIT stall.
       - Repeat: capture the next `length` instructions into the body
         buffer (popped from FIFO over subsequent cycles), then replay
         the body `count` times with iteration index i.

INVARIANTS
    - Issue is in-order. WAIT is the only front-end blocker besides a
      busy target engine.
    - REPEAT bodies may not nest (asserted) and fit REPEAT_MAX_LEN.
"""

from collections import deque

import config
from pymodel.isa import BarInit, Load, Mma, Store, Wait, Repeat


class CmdProc:
    def __init__(self, load_eng, array, store_eng, barriers):
        self.load = load_eng
        self.array = array
        self.store = store_eng
        self.bars = barriers
        self.fifo = deque()
        self.phase_tracker = [0] * config.NUM_BARRIERS
        # WAIT stall
        self._waiting_on = None
        # REPEAT state
        self._body = None        # list of instrs being captured / replayed
        self._capture_left = 0
        self._count = 0
        self._iter = 0           # current iteration index
        self._body_pos = 0

    # ── host side ────────────────────────────────────────────────────
    def push(self, instr):
        assert len(self.fifo) < config.CMD_FIFO_DEPTH, "CMD FIFO overflow"
        self.fifo.append(instr)

    @property
    def idle(self):
        return (not self.fifo and self._waiting_on is None
                and self._body is None)

    # ── cycle behavior ───────────────────────────────────────────────
    def tick(self):
        # 1. WAIT stall: poll the barrier
        if self._waiting_on is not None:
            bar = self._waiting_on
            if self.bars.phase(bar) != self.phase_tracker[bar]:
                self.phase_tracker[bar] ^= 1
                self._waiting_on = None
            return

        # 2. REPEAT body capture (one instr per cycle, like FIFO pop)
        if self._capture_left > 0:
            if not self.fifo:
                return
            self._body.append(self.fifo.popleft())
            self._capture_left -= 1
            if self._capture_left == 0:
                self._iter = 0
                self._body_pos = 0
            return

        # 3. Pick next instruction: replay buffer first, else FIFO
        if self._body is not None and self._capture_left == 0:
            instr = self._body[self._body_pos]
            issued = self._issue(instr, self._iter)
            if issued:
                self._body_pos += 1
                if self._body_pos == len(self._body):
                    self._body_pos = 0
                    self._iter += 1
                    if self._iter == self._count:
                        self._body = None
            return

        if not self.fifo:
            return
        instr = self.fifo[0]

        if isinstance(instr, Repeat):
            assert self._body is None, "nested REPEAT not supported"
            assert 1 <= instr.length <= config.REPEAT_MAX_LEN
            assert 1 <= instr.count <= config.REPEAT_MAX_COUNT
            self.fifo.popleft()
            self._body = []
            self._capture_left = instr.length
            self._count = instr.count
            return

        if self._issue(instr, 0):
            self.fifo.popleft()

    # ── dispatch one instruction; returns True if consumed ───────────
    def _issue(self, instr, i: int) -> bool:
        if isinstance(instr, BarInit):
            self.bars.init(instr.bar, instr.count)
            self.phase_tracker[instr.bar] = 0
            return True

        if isinstance(instr, Load):
            if self.load.busy:
                return False
            self.load.start(instr.bar, instr.gmem + i * instr.gstep,
                            instr.smem + i * instr.sstep, instr.nbytes)
            return True

        if isinstance(instr, Mma):
            if self.array.busy:
                return False
            a_off = instr.a_smem + i * instr.astep
            b_off = instr.b_smem + i * instr.bstep
            sa_off = instr.sa_smem + i * instr.sastep
            sb_off = instr.sb_smem + i * instr.sbstep
            self._fire_mma(instr, a_off, b_off, sa_off, sb_off)
            return True

        if isinstance(instr, Store):
            if self.store.busy:
                return False
            self.store.start(instr.bar, instr.gmem + i * instr.gstep,
                             instr.slot, instr.dtype)
            return True

        if isinstance(instr, Wait):
            bar = instr.bar
            if self.bars.phase(bar) != self.phase_tracker[bar]:
                self.phase_tracker[bar] ^= 1   # already flipped: fall through
                return True
            self._waiting_on = bar
            return True   # consumed; front-end now stalled

        raise ValueError(f"unknown instruction {instr}")

    def _fire_mma(self, instr: Mma, a_off: int, b_off: int,
                  sa_off: int = 0, sb_off: int = 0):
        import numpy as np
        m, n, k = config.MMA_M, config.MMA_N, config.MMA_K
        a = np.frombuffer(self._smem_read(a_off, m * k), dtype=np.uint8).reshape(m, k)
        b = np.frombuffer(self._smem_read(b_off, n * k), dtype=np.uint8).reshape(n, k)
        assert self.store.draining_slot != instr.slot, (
            "MMA targets a slot mid-drain")
        sa = sb = None
        if instr.mx:
            # M E8M0 row scales and N E8M0 col scales, addressed in SMEM like
            # the A/B tiles — the LOAD path delivers them alongside the tiles.
            sa = np.frombuffer(self._smem_read(sa_off, m), dtype=np.uint8)
            sb = np.frombuffer(self._smem_read(sb_off, n), dtype=np.uint8)
        self.array.start(a, b, instr.slot, instr.accum, instr.fmt,
                         mx=instr.mx, scale_a=sa, scale_b=sb)
        self._mma_bar = instr.bar   # arrival fires from sim when array.done

    def _smem_read(self, off, n):
        return self.load.smem.read(off, n)
