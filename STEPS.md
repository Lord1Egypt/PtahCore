# PtahCore — Execution Steps

Working checklist. Tick items via PR. Companion to [PLAN.md](PLAN.md).

## Phase 0 — Scaffold ✅ (2026-06-10, PR #1)
- [x] Choose name (PtahCore) + verify availability
- [x] Write PLAN.md
- [x] Create GitHub repo (public) + About/topics
- [x] `config.py` — single source of truth (MMA_M/N/K=32, SMEM size, slots, FIFO depth)
- [x] `.github/workflows/ci.yml` — lint + pytest on every PR
- [x] `pyproject.toml` (uv, numpy, cocotb, pytest — minimal)
- [x] Placeholder README (full ads-grade README lands at Phase 4 when there's something to show)

## Phase 1 — Golden model ✅ (2026-06-10, PR #1 — done early with scaffold)
- [x] `golden/fp8.py` — e4m3 + e5m2 encode/decode (subnormals, NaN, saturation)
- [x] `golden/matmul_reference.py` — fp8×fp8→fp32 reference vs numpy
- [x] `golden/tests/` — exhaustive 256-value roundtrip + random matmul property tests (20 tests green)

## Phase 2 — pymodel (cycle-level behavioral) ✅ (2026-06-10, PR #3)
- [x] Module specs as docstrings (INPUTS/OUTPUTS/STATE/BEHAVIOR/INVARIANTS per module)
- [x] `pymodel/mac_array.py` — 32×32 broadcast grid w/ distributed TMEM slots (mac_cell folded in; RTL splits it back out)
- [x] `pymodel/smem.py`, `pymodel/gmem.py` — scratchpad + DRAM model
- [x] `pymodel/barrier.py` — mbarrier (pending/expected/tx/phase, flip rule)
- [x] `pymodel/load.py` — async DMA engine, tx-counted arrivals, 16 B/cycle
- [x] `pymodel/store.py` — **async** drain engine (improvement #1 over autogpu) — fp32 + fp8 out
- [x] REPEAT sequencer — lives inside `cmdproc.py` (capture body → strided replay) (improvement #2)
- [x] `pymodel/cmdproc.py` — decode + dispatch + WAIT stall + **auto-phase WAIT** (improvement #3: no software phase bookkeeping; WAIT legal inside REPEAT)
- [x] `pymodel/isa.py` — instruction dataclasses w/ per-iteration strides
- [x] `pymodel/sim.py` — harness; e2e single-tile matmul **bit-exact** vs golden
- [x] e2e: 4-tile K-loop driven by ONE REPEAT block — bit-exact
- [x] e2e: async STORE proven to overlap next kernel's LOAD (the autogpu-can't-do-this test)
- [x] 37 tests green total

## Phase 3 — RTL leaves (each: .sv + cocotb tb vs pymodel twin)
- [x] `rtl/fp8_decode.sv` — comb. fp8→fp32, both formats (+ exhaustive 512-case TB) (PR #4)
- [x] `rtl/fp32_mul.sv` — IEEE-754 RNE multiply (subnormals out of scope, documented) (PR #4)
- [x] `rtl/fp32_add.sv` — full alignment adder, GRS + RNE, bit-exact target vs numpy (PR #4)
- [x] `rtl/mac_cell.sv` — MAC leaf + TMEM slots + drain port (PR #4)
- [x] `rtl/tb/` cocotb suites + Makefile (`make all_leaves`) (PR #4)
- [ ] ⏳ First Verilator run of the four leaf TBs (blocked: `sudo apt-get install verilator`)
- [ ] `rtl/mac_array.sv` (slice first: 4×4, then full via config)
- [ ] `rtl/smem.sv` (banked)
- [ ] `rtl/barrier.sv`
- [ ] `rtl/load.sv`
- [ ] `rtl/store.sv`
- [ ] `rtl/cmdproc.sv` + REPEAT
- [ ] Shared: config.py → SV package generator

## Docs ✅ (2026-06-10, PR #4)
- [x] `docs/ARCHITECTURE.md` — block diagram, memory spaces, engines, module map
- [x] `docs/ISA.md` — full 6-instruction spec + canonical kernels
- [x] `docs/DEVELOPMENT.md` — workflow, RTL/verification conventions, numeric contracts
- [x] `docs/ENGINEERING.md` — honest status table + differentiators vs autogpu

## Phase 4 — RTL integration
- [ ] `rtl/chip_top.sv` + behavioral DRAM TB
- [ ] e2e 32×32×32 matmul bit-exact vs golden
- [ ] Multi-tile + K-loop + REPEAT e2e
- [ ] 🎉 **Ads-grade README + demo assets + About/topics polish**

## Phase 5 — Synthesis smoke
- [ ] Yosys elaboration clean (no inferred latches)
- [ ] sky130 smoke harden of mac_cell
- [ ] ASAP7 first synth: area/timing baseline numbers

## Phase 6 — Hardening: leaves
- [ ] TILE_SPEC.md — abutment boundary contract (pins, PDN, clock entry/exit)
- [ ] mac_cell tile: clean GDS, 0 DRC, timing closed
- [ ] FAILURES.md + RCA discipline docs (capture every flow error once)

## Phase 7 — Hardening: array + chip
- [ ] Abutted row (1×32) with traveling clock
- [ ] Full 32×32 array GDS
- [ ] chip_top GDS — **timing closed honestly, zero masked hold violations**
- [ ] 2D/3D layout viewer deployed (GDS → web)

## Phase 8 — HW block scaling
- [ ] MX-style per-tile scale in LOAD path; ISA flag; golden + pymodel + RTL

## Phase 9 — 2:4 structured sparsity
- [ ] Metadata format; sparse operand select in mac_cell; 2× throughput e2e proof

## Phase 10 — Stretch
- [ ] 64×64 config build
- [ ] Multi-shape MMA (M/N/K operand fields return)
- [ ] GDS gallery + blog-style writeup in repo
