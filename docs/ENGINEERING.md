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
| 3 | RTL modules vs pymodel (cocotb) | ✅ done — 11 units, 45 tests |
| 4 | Full RTL integration + e2e | ✅ done — chip_top runs multi-tile matmul |
| 5 | Synthesis smoke (Yosys elaboration + area) | ✅ done — 0 latches, baseline in docs/SYNTHESIS.md |
| 6 | Hardening: leaf tiles | 🔨 in progress — ORFS flow + tile spec ready, P&R pending |
| 7 | Hardening: array + chip (traveling clock) | ⬜ |
| 8 | HW block scaling (MX-style) | ⬜ |
| 9 | 2:4 structured sparsity | ⬜ |
| 10 | Stretch: 64×64, multi-shape MMA | ⬜ |

**Current state in one line:** **the whole chip works.** `chip_top.sv` wires
every module together — cmdproc → barrier → smem → load → mma_unit (fetch +
32×32 array) → store → DRAM — and runs a full multi-tile FP8 matmul end to
end through real Verilog, **bit-exact against the golden model**, including a
REPEAT-driven 4-tile K-loop. 52 RTL cocotb tests + 37 Python tests, all green.
Next: synthesis (Yosys → sky130 → ASAP7) and 7nm hardening.

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
| [SYNTHESIS.md](SYNTHESIS.md) | Yosys elaboration + generic gate-level area baseline |
| [TILE_SPEC.md](TILE_SPEC.md) | Abutment boundary contract (written before scaling) |
| [INVARIANTS.md](INVARIANTS.md) | Machine-checkable build + RTL invariants (incl. the no-masked-hold rule) |
| [HARDENING.md](HARDENING.md) | ASAP7 P&R results log + failure table (honest numbers only) |
| [../PLAN.md](../PLAN.md) | The roadmap contract (phases, decisions, risks) |
| [../STEPS.md](../STEPS.md) | Live execution checklist, ticked per PR |
