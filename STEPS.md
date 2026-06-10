# PtahCore — Execution Steps

Working checklist. Tick items via PR. Companion to [PLAN.md](PLAN.md).

> **▶ RESUME HERE (as of 2026-06-11, after PR #8):**
> Phases 0–4 complete. **The whole chip works** — `chip_top.sv` runs a full
> multi-tile matmul end-to-end through real Verilog, bit-exact vs golden.
> **Score: 89 tests green (52 RTL + 37 Python), 8 PRs merged.**
> **Next up = Phase 5: synthesis smoke** — Yosys elaboration (no latches),
> then sky130 + ASAP7 first synth for area/timing baselines. Run
> `cd rtl/tb && make all_leaves` to re-verify all 13 RTL units first.

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
- [x] First Verilator run: **all 4 leaves PASS** — 14 cocotb tests, bit-exact (fp8_decode 512/512 exhaustive; fp32_add 4051 cases incl. cancellation/carry/RNE-tie edges) (PR #5)
  - Fixes shaken out: `small` is an SV reserved keyword → `algn`; fp32_mul missing default assignments (latch warnings); per-TOP sim_build dirs; conda-PYTHONHOME vs Verilator helper scripts → `python3-clean` wrapper passed as command-line make var; cocotb pinned `<2` (Debian Verilator 5.020 < 5.036 required by cocotb 2.x)
- [x] `rtl/fp8_encode.sv` — comb fp32→fp8 e4m3 RNE saturating (STORE path) + roundtrip/boundary/sweep TB (PR #6)
- [x] `rtl/smem.sv` — 1 write + 2 read ports, registered reads, barrier-region guard (PR #6)
- [x] `rtl/barrier.sv` — mbarrier file, 5 producer ports, same-cycle multi-arrive, flip rule (PR #6)
- [x] `rtl/load.sv` — async DMA engine, 16 B/cycle, issue-time tx, done pulse (PR #6)
- [x] `rtl/store.sv` — **async** drain engine, fp32 + fp8 out via fp8_encode (PR #6)
- [x] All verified: `make all_leaves` = 9 units, 31 RTL cocotb tests green
- [x] `rtl/mac_array.sv` — 32×32 broadcast grid, M+N edge decoders, distributed-TMEM drain; bit-exact at 4×4×8 vs golden (PR #7)
- [x] `rtl/cmdproc.sv` — FIFO front-end, REPEAT capture/replay w/ strides, **auto-phase WAIT**, engine-busy stall + `cmdproc_tb_top.sv` (cmdproc + real barrier) (PR #7)
- [x] **Phase 3 RTL COMPLETE**: 11 units, 45 RTL cocotb tests + 37 Python = 82 green
- [ ] Shared: config.py → SV package generator (deferred to Phase 4 chip_top wiring)

## Docs ✅ (2026-06-10, PR #4)
- [x] `docs/ARCHITECTURE.md` — block diagram, memory spaces, engines, module map
- [x] `docs/ISA.md` — full 6-instruction spec + canonical kernels
- [x] `docs/DEVELOPMENT.md` — workflow, RTL/verification conventions, numeric contracts
- [x] `docs/ENGINEERING.md` — honest status table + differentiators vs autogpu

## Phase 4 — RTL integration ✅ (2026-06-11, PR #8)
- [x] `rtl/mma_unit.sv` — operand-fetch FSM (chose option (a)) + mac_array;
      streams A/B tiles from SMEM into the array's wide ports, presents the
      cmdproc's standard MMA interface. 2 tests (fetch+MMA+drain, accumulate)
- [x] `rtl/chip_top.sv` — cmdproc + barrier + smem + load + mma_unit + store,
      fully wired per docs/ARCHITECTURE.md; external pins = instr push + GMEM
      read/write ports (behavioral DRAM in TB)
- [x] e2e single-tile matmul, fp32 out — **bit-exact vs golden**
- [x] e2e single-tile, fp8 out — bit-exact
- [x] e2e **4-tile K-loop via REPEAT** with strided gmem loads — bit-exact
- [x] **Pipeline-hazard fix in cmdproc**: engine `busy` rises one cycle after
      a registered `start`; added per-engine issued-last-cycle guards
      (ld_iss_d/mma_iss_d/st_iss_d) so the front-end can't double-issue into
      an engine in that window
- [ ] config.py → SV package generator (deferred; -G overrides suffice for now)
- [ ] 🎉 **Ads-grade README + demo assets + About/topics polish** (Phase 5+)

**Note:** went with operand-fetch option (a) — keeps the verified mac_array
untouched. Column-streaming (option b) is a Phase 6 hardening refactor if the
fetch latency hurts timing.

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
