# PtahCore — Master Plan

> **PtahCore** — an open-source FP8 tensor accelerator, written from scratch in SystemVerilog,
> hardened to GDSII on the open 7nm ASAP7 PDK with a 100% open-source flow.
> Named after **Ptah**, the Egyptian creator god and patron of craftsmen & architects.

**Author:** Lord1Egypt (Mohamed Mounir)
**Started:** 2026-06-10
**Status:** Phase 0 — planning

---

## 1. Vision

Build a real, sign-off-quality matmul accelerator chip — Verilog → synthesis →
place-and-route → GDSII you could theoretically send to a foundry — using only
open-source tools, with every line of RTL written by us.

**Prior art studied (not copied):** [npip99/autogpu](https://github.com/npip99/autogpu)
proved the concept (fp8 32×32 systolic array on ASAP7). We design our own
architecture and explicitly target the weaknesses its author documents publicly:

| autogpu's documented limitation | PtahCore's answer |
|---------------------------------|-------------------|
| chip_top never closes timing (−205 ps setup; hold masked with `HOLD_SLACK_MARGIN=-2000`) | Traveling-clock / source-synchronous design **from day one at chip level**, not retrofitted |
| `.lib` characterization mismatch → ~1 ns STA skew | Abutment-first methodology; no parent CTS over hardened macros |
| STORE is synchronous (no epilogue overlap) | **Async STORE** with barrier arrival from v1 |
| MMA shape hardwired 32×32×32 | Same v1 simplicity, but config-driven everywhere + planned multi-shape |
| No sparsity | **2:4 structured sparsity** (NVIDIA-style) = 2× effective throughput, planned Phase 9 |
| fp8 scaling punted to host | **Hardware per-tile scaling** (MX-style block scaling), planned Phase 8 |
| 256-deep instr FIFO overflows on large kernels | **`REPEAT` loop primitive** in the ISA from v1 |
| Single fp8 format (e4m3) | **Both e4m3 + e5m2** operand formats from v1 |

---

## 2. Architecture (v1)

Blackwell-shaped FP8 matmul accelerator. Three memory spaces, three engines,
async issue with barrier completion. No general-purpose compute.

```
 instr stream → [CMD FIFO] → [CMDPROC] ←→ [BARRIERS (in SMEM)]
                                │
                ┌──────────┬────┴─────┬──────────┐
                ▼          ▼          ▼          ▼
             [LOAD]   [MAC ARRAY] [STORE]    [REPEAT
                │       32×32        │        sequencer]
                ▼       ▲    │drain  ▼
             GMEM→SMEM  SMEM 1elem/cy GMEM
```

### Decisions (v1)

| Decision | Choice | Why |
|----------|--------|-----|
| Array size | 32×32 MAC cells | Proven hardennable at 7nm; bigger = Phase 10 |
| Dataflow | Output-stationary, broadcast operands | Accumulators never move; only drain |
| Operand types | fp8 **e4m3 AND e5m2** (per-instruction flag) | Superset of autogpu v1 |
| Accumulate | fp32, distributed in MAC cells ("TMEM") | Blackwell-style |
| Accumulator slots | 4 per cell, config-driven | Multi-tile workloads |
| STORE | **async** (barrier arrival) + optional fp32→fp8 convert | Epilogue overlap = real perf win |
| ISA | LOAD / MMA / STORE / BAR.INIT / WAIT / **REPEAT** | REPEAT solves FIFO overflow elegantly |
| Clocking | Source-synchronous traveling clock, chip-wide | The #1 lesson from autogpu's timing failure |
| Config | Single `config.py` → generates SV package + Verilator flags | Never hardcode dimensions |

### ISA sketch (64-bit fixed instructions)

| Op | Semantics |
|----|-----------|
| `BAR.INIT bar, count` | init mbarrier in SMEM |
| `LOAD bar, gmem, smem, bytes` | async DMA gmem→smem; tx-counted arrival |
| `MMA bar, A, B, D, accum, fmt` | async fp8 matmul into TMEM slot; `fmt` = e4m3/e5m2 |
| `STORE bar, gmem, D, dtype` | **async** TMEM drain → gmem; fp32 or fp8 out |
| `WAIT bar, phase` | block front-end until phase flip |
| `REPEAT count, len` | hardware loop: re-issue next `len` instructions `count` times |

---

## 3. Toolchain (all open source)

| Stage | Tool |
|-------|------|
| RTL | SystemVerilog (our own) |
| Lint/sim | Verilator 5 + cocotb |
| Golden model | Python + numpy (bit-exact fp8/fp32) |
| Synthesis | Yosys |
| P&R → GDSII | OpenROAD-flow-scripts (ORFS) |
| PDK | ASAP7 (7nm predictive, open) + sky130 smoke tests |
| CI | GitHub Actions: lint + unit tests on every PR |

---

## 4. Phases

**Phase 0 — Scaffold (this week)**
Repo, plan, config.py, CI skeleton, golden fp8 model + tests.

**Phase 1 — Golden model**
Python bit-exact fp8 (e4m3 + e5m2) encode/decode + matmul reference vs numpy.

**Phase 2 — Python behavioral model (pymodel)**
Cycle-level models: mac cell → array → smem/gmem → load/store → barriers →
cmdproc → REPEAT sequencer. Per-module specs + tests. End-to-end matmul green.

**Phase 3 — RTL, leaf modules**
SystemVerilog per module, each verified against its pymodel twin via cocotb.
Order: mac_cell → mac array slice → smem bank → barrier → load → store → cmdproc.

**Phase 4 — RTL integration**
`chip_top.sv` + behavioral DRAM testbench. Full 32×32×32 matmul end-to-end,
bit-exact vs golden. Multi-tile + K-loop + REPEAT.

**Phase 5 — Synthesis smoke**
Yosys + sky130 first (fast sanity), then ASAP7. Area/timing first numbers.

**Phase 6 — Hardening: leaves**
ORFS harden mac_cell tile → clean DRC, timing closed. Tile abutment contract
defined BEFORE scaling (autogpu lesson: retrofit = pain).

**Phase 7 — Hardening: array + chip**
Abutted 32×32 array → full chip_top with traveling clock. Goal that autogpu
never reached: **chip-level timing closed, zero masked hold violations.**

**Phase 8 — HW block scaling**
MX-style per-tile scale factors in LOAD path. Removes host-side prescaling.

**Phase 9 — 2:4 structured sparsity**
Metadata-indexed operand select in MAC cells → 2× effective FLOPs.

**Phase 10 — Stretch**
64×64 array · multi-shape MMA · async epilogue fusion · published GDS gallery.

---

## 5. Success criteria

1. ✅ Full RTL matmul, bit-exact vs numpy, all suites green (autogpu parity)
2. ✅ Chip-level GDSII on ASAP7 with **honest timing closure** (autogpu superiority)
3. ✅ ≥2 features autogpu lacks (async STORE, REPEAT, e5m2, scaling, sparsity)
4. ✅ README so good it markets itself; live 2D/3D layout viewer
5. ✅ Every phase = PRs with green CI (Pull Shark stacking 🏆)

## 6. Risks

| Risk | Mitigation |
|------|-----------|
| 7nm timing closure is genuinely hard | sky130 first; abutment + traveling clock from day 1; autogpu's public postmortems = our free map of every pothole |
| Scope explosion | v1 = exactly 6 instructions, one tile shape; everything else phased |
| ASAP7 PDK gaps (antenna, RC) | Document as known-limits like autogpu did honestly |
| Solo bandwidth | pymodel-first = cheap iteration; RTL only after behavior is proven |

---

*Steps checklist lives in [STEPS.md](STEPS.md). This plan is the contract — update it via PR when decisions change.*
