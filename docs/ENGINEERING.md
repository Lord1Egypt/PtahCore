# PtahCore — Engineering Status & Map

The technical companion to the README: what the chip is, where the build
actually stands (honestly), and where every other doc lives.

PtahCore is a minimal FP8 matmul accelerator in SystemVerilog — six
instructions (`LOAD`, `MMA`, `STORE`, `BAR.INIT`, `WAIT`, `REPEAT`).
Blackwell-style: distributed tensor memory (TMEM) for accumulators inside the
per-(i,j) MAC cells, separate from SMEM operand storage. No general-purpose
compute, no branches. `MMA_M = MMA_N = MMA_K = 32`, fp8 inputs (**both e4m3
and e5m2**), fp32 accumulate. `config.py` is the canonical parameter source
for both Python and SV.

## Status

| Phase | What | Status |
|-------|------|--------|
| 0 | Scaffold: repo, config, CI | ✅ done |
| 1 | Golden fp8 model (e4m3 + e5m2) | ✅ done — 20 tests |
| 2 | Cycle-level pymodel, e2e matmul | ✅ done — 37 tests, bit-exact |
| 3 | RTL leaves vs pymodel (cocotb) | 🔨 in progress |
| 4 | Full RTL integration + e2e | ⬜ |
| 5 | Synthesis smoke (sky130 → ASAP7) | ⬜ |
| 6 | Hardening: leaf tiles | ⬜ |
| 7 | Hardening: array + chip (traveling clock) | ⬜ |
| 8 | HW block scaling (MX-style) | ⬜ |
| 9 | 2:4 structured sparsity | ⬜ |
| 10 | Stretch: 64×64, multi-shape MMA | ⬜ |

**Current state in one line:** the full machine runs end-to-end in the
cycle-level Python model (bit-exact), and **9 RTL modules** are written and
**verified bit-exact under Verilator** — the arithmetic leaves (fp8_decode,
fp8_encode, fp32_mul, fp32_add, mac_cell) plus the memory/sync/engine layer
(smem, barrier, load, store). 31 RTL cocotb tests + 37 Python tests, all
green. Remaining for full chip: the MAC array slice and the cmdproc, then
top-level integration.

## Differentiators vs. prior art

PtahCore's architecture deliberately fixes the documented weak points of
[npip99/autogpu](https://github.com/npip99/autogpu) (studied, not copied —
every line here is original):

| Theirs | Ours |
|--------|------|
| Sync STORE stalls the front-end | Async STORE; epilogue overlap proven by test |
| 256-deep FIFO overflows on big kernels | REPEAT: K-loop = 6 entries for any K |
| Software phase bookkeeping on WAIT | Auto-phase WAIT tracked in cmdproc |
| e4m3 only | e4m3 + e5m2 per-instruction |
| chip-level timing closed only with masked hold violations | (target) traveling clock from day one, honest closure |

## Docs

| File | Purpose |
|------|---------|
| [ARCHITECTURE.md](ARCHITECTURE.md) | Block diagram, memory spaces, engines, module map |
| [ISA.md](ISA.md) | The six instructions, barrier semantics, canonical kernels |
| [DEVELOPMENT.md](DEVELOPMENT.md) | **Read before writing code** — workflow, conventions, numeric contracts |
| [../PLAN.md](../PLAN.md) | The roadmap contract (phases, decisions, risks) |
| [../STEPS.md](../STEPS.md) | Live execution checklist, ticked per PR |

Planned (created when their phases start): `docs/FAILURES.md` (flow error
lookup), `docs/INVARIANTS.md` (build-system + RTL invariants),
`docs/TILE_SPEC.md` (abutment boundary contract — written BEFORE scaling,
not retrofitted).
