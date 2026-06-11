# PtahCore — Architecture

A minimal FP8 matmul accelerator, Blackwell-shaped. Three memory spaces, three
execution engines, async issue with mbarrier completion, plus a hardware REPEAT
sequencer. No general-purpose compute, no branches, no register file.

See [ISA.md](ISA.md) for the instruction set. This doc describes the *hardware*:
what modules exist, how data flows, and the per-module spec convention.

## 1. System block diagram

```
                 ┌─────────────────┐
        instr →  │  command FIFO   │ (CMD_FIFO_DEPTH = 256)
        stream   └────────┬────────┘
                          │ pop (1/cycle)
                 ┌────────▼────────┐         ┌──────────────┐
                 │  command proc   │◄───────►│   barriers   │
                 │  decode +       │  WAIT   │ (mbarrier    │
                 │  dispatch +     │  query  │  file, flips │
                 │  REPEAT replay  │         │  on complete)│
                 │  + phase track  │         └──────▲───────┘
                 └──┬─────┬─────┬──┘                │ arrive
              start │     │     │                   │ add_tx / sub_tx
                    ▼     ▼     ▼                   │
                 ┌────┐ ┌─────────────┐ ┌─────┐     │
                 │LOAD│ │  mac_array  │ │STORE│─────┘
                 └─┬──┘ │   32 × 32   │ └──┬──┘
                   │    └──┬───▲──────┘    │
                   │       │   │ drain     │
        gmem rd /  │  smem rd  │ stream    │
        smem wr    │  (bcast)  └───────────┤
                   ▼       ▼               ▼ gmem wr
                ┌─────┐ ┌──────┐        ┌─────┐
                │GMEM │ │ SMEM │        │GMEM │
                └─────┘ └──────┘        └─────┘
```

The arrows are dedicated point-to-point paths — there is no shared bus. LOAD's
gmem-read and the array's smem-read can happen in the same cycle; the async
STORE's gmem-write overlaps both.

## 2. Memory spaces

| Space | Owner | Width | Latency |
|-------|-------|-------|---------|
| GMEM | external (TB model in pymodel; off-chip DRAM in real HW) | byte-addressed | 1 cycle in model |
| SMEM | on-chip scratchpad | byte-addressed; first `NUM_BARRIERS*16` B reserved for mbarriers | 1 cycle rd / 1 cycle wr |
| TMEM | distributed: `TMEM_SLOTS` fp32 accumulators inside each of the 1024 `mac_cell` leaves | one slot = an MMA_M×MMA_N fp32 tile | RMW each K-step; drained 1 elem/cycle |

## 3. Execution engines

Every engine has the same shape: `start` pulse + operand bundle in, runs N
cycles, signals the barrier file on completion. Engines never talk to each
other directly — only through SMEM, TMEM, GMEM, and barriers.

- **LOAD** — DMA gmem → smem at `LOAD_BYTES_PER_CYCLE` (16 B/cycle).
  Issue-time: `bar.tx += bytes` (atomic, before any byte moves — a WAIT can
  never observe an in-flight-but-unaccounted LOAD). Completion:
  `bar.tx -= bytes; bar.pending -= 1`.
- **mac_array** — 32×32 grid of `mac_cell` leaves. An MMA broadcasts one
  column of A (M lanes) and one column of B (N lanes) per cycle for K cycles;
  cell (i,j) computes `acc[slot] += fp32(A[i,k]) * fp32(B[j,k])`. fp8→fp32
  decode happens once per row/column lane at the array edge (64 decoders,
  not 2048). Completion: `bar.pending -= 1`.
- **STORE** — **async** (PtahCore improvement: autogpu's STORE stalls the
  front-end). Drains one fp32 element per cycle from a TMEM slot, row-major,
  optional fp32→fp8-e4m3 convert, writes gmem. Completion: `bar.pending -= 1`.

## 4. Async issue model

The command processor pops one instruction per cycle (when not stalled) and
dispatches to the matching engine, fire-and-forget. The front-end stalls only
on (a) WAIT, (b) target engine busy.

```
issue            run               complete
  ▼               ▼                   ▼
LOAD ─[tx+=N]────┼──[bytes flowing]──┼─[tx-=N, pending-=1]─→ flip?
MMA  ────────────┼──[K cycles]───────┼─[pending-=1]────────→ flip?
STORE ───────────┼──[M·N cycles]─────┼─[pending-=1]────────→ flip?
                                flip when pending==0 && tx==0:
                                phase ^= 1; pending = expected
```

**Auto-phase WAIT** (PtahCore improvement): the cmdproc keeps one expected-
phase bit per barrier. `WAIT bar` blocks until `bar.phase != tracker[bar]`,
then toggles the tracker. No phase operand, no software bookkeeping, and WAIT
is legal inside REPEAT bodies.

**REPEAT sequencer** (PtahCore improvement): `REPEAT count, len` captures the
next `len` instructions and replays them `count` times. Body instructions
carry optional per-iteration address strides (`gstep`, `sstep`, `astep`,
`bstep`). A K-loop is 6 FIFO entries regardless of K — the FIFO-overflow
problem of naive Blackwell-style streams is gone.

## 5. Cycle model (pymodel)

Each module exposes `tick()`, called once per simulated clock:

- A module's outputs reflect state **after** the rising edge.
- Other modules sample those outputs the **next** cycle (registered, like RTL).
- Harness tick order (determinism only): cmdproc → load → array → store →
  MMA-done barrier arrival.

## 6. Module spec convention

Every pymodel module's docstring is its spec, and the RTL twin implements
exactly that contract:

```
<module> — <one-line purpose>

INPUTS (sampled at tick start)
OUTPUTS (valid after tick)
INTERNAL STATE
BEHAVIOR (per tick)   — numbered rules
INVARIANTS            — statements that always hold
```

If BEHAVIOR needs more than ~10 rules, the module is doing too much — split it.

## 7. Module map

| Layer | File | Role |
|-------|------|------|
| golden | `golden/fp8.py` | bit-exact e4m3 + e5m2 encode/decode |
| golden | `golden/matmul_reference.py` | sequential-K fp32 reference |
| pymodel | `pymodel/mac_array.py` | 32×32 grid + distributed TMEM |
| pymodel | `pymodel/smem.py`, `gmem.py` | memories |
| pymodel | `pymodel/barrier.py` | mbarrier file |
| pymodel | `pymodel/load.py`, `store.py` | DMA engines |
| pymodel | `pymodel/cmdproc.py` | FIFO, dispatch, WAIT, REPEAT |
| pymodel | `pymodel/sim.py` | harness |
| RTL | `rtl/fp8_decode.sv` | comb. fp8→fp32, both formats |
| RTL | `rtl/fp32_mul.sv`, `fp32_add.sv` | IEEE-754 RNE arithmetic |
| RTL | `rtl/mac_cell.sv` | MAC leaf + TMEM slots |
| RTL | `rtl/mac_tile.sv` | abutment tile: mac_cell + TILE_SPEC boundary (feedthroughs, traveling clock, drain chain) |
| RTL | `rtl/mac_row.sv` | 1×N west→east chain of mac_tiles |
| RTL | `rtl/tb/` | cocotb suites vs pymodel/numpy |

## 8. Parameters

Everything derives from `config.py` — the single source of truth for both
Python and SystemVerilog (RTL Makefiles pull values via
`python3 -c "from config import ..."` into Verilator `-G` flags / generated
packages). Never hardcode a dimension.
