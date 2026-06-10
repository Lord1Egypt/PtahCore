# PtahCore — Execution Steps

Working checklist. Tick items via PR. Companion to [PLAN.md](PLAN.md).

## Phase 0 — Scaffold
- [x] Choose name (PtahCore) + verify availability
- [x] Write PLAN.md
- [ ] Create GitHub repo (public) + About/topics
- [ ] `config.py` — single source of truth (MMA_M/N/K=32, SMEM size, slots, FIFO depth)
- [ ] `.github/workflows/ci.yml` — lint + pytest on every PR
- [ ] `pyproject.toml` (uv, numpy, cocotb, pytest — minimal)
- [ ] Placeholder README (full ads-grade README lands at Phase 4 when there's something to show)

## Phase 1 — Golden model
- [ ] `golden/fp8.py` — e4m3 + e5m2 encode/decode (subnormals, NaN, saturation)
- [ ] `golden/matmul_reference.py` — fp8×fp8→fp32 reference vs numpy
- [ ] `golden/tests/` — exhaustive 256-value roundtrip + random matmul property tests

## Phase 2 — pymodel (cycle-level behavioral)
- [ ] Module spec template (INPUTS/OUTPUTS/STATE/BEHAVIOR/INVARIANTS per module)
- [ ] `pymodel/mac_cell.py` — fp8 MAC + 4-slot fp32 accumulator + drain port
- [ ] `pymodel/mac_array.py` — 32×32 broadcast grid
- [ ] `pymodel/smem.py`, `pymodel/gmem.py` — banked scratchpad + DRAM model
- [ ] `pymodel/barrier.py` — mbarrier (pending/expected/tx/phase, flip rule)
- [ ] `pymodel/load.py` — async DMA engine, tx-counted arrivals
- [ ] `pymodel/store.py` — **async** drain engine (improvement #1 over autogpu)
- [ ] `pymodel/repeat.py` — REPEAT sequencer (improvement #2)
- [ ] `pymodel/cmdproc.py` — decode + dispatch + WAIT stall
- [ ] `pymodel/sim.py` — harness; e2e single-tile matmul bit-exact
- [ ] e2e: K-loop pipelined matmul w/ double-buffered SMEM, REPEAT-driven

## Phase 3 — RTL leaves (each: .sv + cocotb tb vs pymodel twin)
- [ ] `rtl/mac_cell.sv`
- [ ] `rtl/mac_array.sv` (slice first: 4×4, then full via config)
- [ ] `rtl/smem.sv` (banked)
- [ ] `rtl/barrier.sv`
- [ ] `rtl/load.sv`
- [ ] `rtl/store.sv`
- [ ] `rtl/cmdproc.sv` + REPEAT
- [ ] Shared: config.py → SV package generator

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
