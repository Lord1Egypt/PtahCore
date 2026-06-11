# PtahCore — Execution Steps

Working checklist. Tick items via PR. Companion to [PLAN.md](PLAN.md).

> **▶ RESUME HERE (as of 2026-06-11 ~22:30, Phase 7c-3 attempt 2 RUNNING,
> branch `feat/phase7c3-grid-harden`):** First grid attempt FAILED at CTS
> (RSZ-0060) — root cause MEASURED and fixed: southbound drain arc is
> 52.6 ps/row vs B 88.9 vs my δs=150 guess → tile **rev C** (vertical
> set_min_delay 85 floors) + grid δs=85; full story in HARDENING.md
> failure log. Artifacts wiped, **attempt 2 running detached**: log
> /tmp/grid_harden2.log (tile rev-C rebuild → abstract → clk-arc patch
> → 1024-macro grid). If dead after /clear: `tail /tmp/grid_harden2.log`,
> `docker ps`. After success: 6_finish.rpt + 5_route_drc.rpt, then
> `python3 flow/check_abutment.py --def flow/results/asap7/mac_grid/base/6_final.def
> --lef flow/results/asap7/mac_grid_mac_tile/base/mac_tile.lef --cols 32
> --rows 32 --x0 2.16 --y0 12.96` and
> `python3 flow/report_clock_table.py --design mac_grid --cols 32 --rows 32`
> (arrivals must grow ~85/row + ~82/col). Debug recipe that found the
> waves: OpenSTA on 3_5_place_dp.odb + 3_place.sdc (see HARDENING.md).
> Then HARDENING.md results section, STEPS, docs/img renders, PR.
> Re-verify RTL: `cd rtl/tb && make all_leaves`; Python: `pytest golden pymodel -q`.
>
> *(previous checkpoint, after Phase 7b-3):*
> Phases 0–7b complete — **four GDS out**: mac_cell, hierarchical row,
> mac_tile, and the headline: **the ABUTTED TRAVELING-CLOCK ROW** — 32
> tiles pin-on-pin, zero gap, NO row CTS, clock marching +82.34 ps/tile,
> setup **+180 ps** / hold **+48 ps** @ 250 MHz, 0 violations, DRC clean
> across all 31 abutted boundaries. This is the clocking thesis autogpu
> never closed, proven at row scale. Build with
> `ORFS_MAKE_ARGS='NUM_CORES=6' flow/harden_abutted_row.sh` (orchestrates
> block → abstract → clk-arc patch → row; the patch step is MANDATORY —
> without it 31 of 32 tiles are silently unconstrained, see HARDENING.md).
> Verify with `flow/check_abutment.py`. Drain is now REGISTERED at the
> row boundary (+1 cycle STORE latency, 94 tests bit-exact).
> **Score: 94 tests green (57 RTL + 37 Python), 17 PRs merged.**
> **Next — Phase 7c:** the 32×32 array — stack 32 rows by vertical
> abutment (height quantum already baked in), traveling B delivery along
> the north edge (the SDC contract the row already models), drain chains
> south, row decoders. Then 7d chip_top.
> Re-verify RTL: `cd rtl/tb && make all_leaves`.

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

## Phase 5 — Synthesis smoke  (partly ✅ 2026-06-11, PR #9)
- [x] Yosys elaboration clean (no inferred latches) — `synth/elaborate.ys`,
      `hierarchy -check` + `-assert-none t:$dlatch`; runs in CI now
- [x] Generic gate-level area baseline — `synth/area.ys` → `docs/SYNTHESIS.md`:
      fp8_decode 60 · fp8_encode 388 · fp32_add 1627 · fp32_mul 3769 ·
      mac_cell ~5790 gates → array ≈ 5.9M gates (fp32 mul is 65% of a cell)
- [x] Yosys `break` not supported → rewrote fp32_add MSB scan as ascending
      priority encoder (still bit-exact, re-verified)
- [ ] sky130 smoke harden of mac_cell (needs OpenROAD/ORFS — heavy install)
- [ ] ASAP7 first synth: real area/timing baseline (needs OpenROAD + ASAP7 PDK)

**Note:** SMEM (64 KiB behavioral array) is elaborated + latch-checked but NOT
gate-mapped — it's an SRAM macro at hardening, and expanding it to FFs OOM-ed
the WASM Yosys. Real P&R area/timing arrive with OpenROAD in Phase 6.

## Phase 6 — Hardening: leaves ✅ (2026-06-11, PRs #10–#14 — **first GDS**)
- [x] `docs/TILE_SPEC.md` — abutment boundary contract (outline, edge power,
      opposing-edge clock, per-edge signal pins, .lib characterisation) (PR #10)
- [x] `docs/INVARIANTS.md` — machine-checkable build/RTL invariants; B4 bans
      negative hold margin (autogpu's cardinal sin) (PR #10)
- [x] `docs/HARDENING.md` — honest results log + failure table (PR #10)
- [x] ORFS flow infra: `flow/designs/asap7/mac_cell/{config.mk,constraint.sdc}`
      (250 MHz target) + `flow/harden.sh` docker runner (PR #10)
- [x] Solved WSL2 docker-credential-desktop.exe blocker → `DOCKER_CONFIG=/tmp/dockercfg`
      with `{}` config skips the Windows cred helper for public pulls
- [x] Pulled `openroad/orfs:latest` (6.5 GB) + ran `flow/harden.sh mac_cell`
      on REAL ASAP7 → synth + floorplan + placement clean (PR #11)
- [x] First real numbers: mac_cell **833 µm²**, 49% util; **fails 250 MHz**
      (WNS −2237 ps) — single-cycle fp32 mul→add→acc tops out ~160 MHz
- [x] Failure log populated (HARDENING.md): VERILOG_DEFINES -D prefix, SDC
      remove_from_collection, **CTS SIGILL (WSL2 CPU lacks AVX-class instr —
      env blocker, stops CTS→route→GDS here)**
- [x] **Phase 6b: pipelined MAC cell** — split mul↔add; array absorbs +1
      latency via flush cycle; **bit-exact (89 tests)** (PR #12)
- [x] **Phase 6c: found the picosecond units bug** — ASAP7 SDC is in ps;
      `clk_period 4.0` meant 4 ps (250 GHz). Fixed to `4000`. (PR #13)
- [x] **mac_cell CLOSES 250 MHz setup** — worst slack **+1994 ps**, crit path
      ~2.0 ns (≈500 MHz capable), **675 µm²**. The "fails timing" saga was the
      unit bug; the design was always fine.
- [x] Reverted the internal-mul split (registering raw product measured worse);
      final cell = combinational fp32_mul, register full product, comb. add
- [x] **Phase 6d: SIGILL root-caused + first GDS** (PR #14) — the crash was
      never TritonCTS: CTS + hold repair had already completed in the log.
      It was `run_lec_test` exec-ing the image's `kepler-formal` LEC binary
      (needs AVX-512; this host has AVX2). `LEC_CHECK = 0` skips it
      (equivalence already covered by the bit-exact cocotb suite) → full
      CTS→route→GDS runs fine on WSL2, ~6 min end-to-end
- [x] Hold closed honestly: default `HOLD_SLACK_MARGIN=0` left 2 post-route
      paths at −1.11 ps → set `+15` (positive margin = MORE slack demanded,
      the opposite of masking) → **0 hold violations, worst +13.01 ps**
- [x] **`mac_cell` GDS complete, signoff clean**: setup +1928 ps @ 250 MHz,
      hold +13 ps, 0 slew/cap/fanout violations, **DRC clean**, 750 µm²
      @ 44% util, ~480 MHz capable. Layout renders in docs/img/
- [ ] (Phase 7 stretch, only if pushing past ~480 MHz) Kulisch fixed-point
      accumulator and/or width-matched fp8 multiplier

## Phase 7 — Hardening: array + chip
- [x] **Phase 7a: hierarchical 1×32 row GDS** (2026-06-11) — `rtl/mac_row.sv`
      extracted as the physical tiling unit (mac_array now stamps M rows;
      bit-exact, 91 tests green incl. 2 new row TBs); `mac_cell` consumed as
      a hard macro via ORFS `BLOCKS` (M1–M5 macro / M6–M7 parent layer
      split); deterministic `place_macro` row pitch. Signoff: setup +386 ps /
      hold +438 ps @ 250 MHz, 0 setup/hold violations, DRC clean, 66,284 µm²
      @ 56% util. 3 max-slew pins ≤39 ps over lib limit recorded honestly
      (HARDENING.md) — die in 7b's re-layout
- [x] Found + documented the virtual-clock trap: vclk latency must be
      `-source` or post-CTS `set_propagated_clock` reverts it to ideal
      (phantom −669 ps hold wall, CTS buffer-cap death)
- [x] vclk honesty check exercised: model tightened 1150 → 750 ps to match
      measured insertion (~710 ps), hold re-closed ~400 ps harder
- [x] **Phase 7b-1: tile-boundary RTL** (2026-06-11) — `rtl/mac_tile.sv`
      wraps the verified mac_cell with the TILE_SPEC contract: west-in /
      east-out feedthroughs (clk, rst, en/zero/slot/drain_slot, row_hit, A),
      north-in / south-out (B column broadcast, row_hit-selected vertical
      drain chain — designed now so the tile never re-hardens when rows
      stack). mac_row = pure west→east tile chain; mac_array/mma_unit/
      chip_top untouched. Bit-exact: **94 tests** (57 RTL + 37 Python),
      3 new tile TBs (feedthroughs, drain chain select, wrapped-core MAC)
- [x] **Phase 7b-2: mac_tile hardened — third GDS** (2026-06-11) — fixed
      46.44×46.44 µm site-aligned outline; all 73 mirrored pin pairs
      (west↔east, north↔south) verified coordinate-exact in the DEF;
      signoff +1620 ps setup / +15 ps hold, **zero violations of any type**,
      DRC clean, 773 µm² @ 39%. Characterised .lib: clk feedthrough ~89 ps ≈
      A feedthrough ~84–98 ps — traveling clock matched to the data wave by
      construction. Open for 7b-3: verify row STA consumes the
      falling_edge-encoded clk_in→clk_out arc correctly
- [x] **Phase 7b-3: ABUTTED TRAVELING-CLOCK ROW — fourth GDS** (2026-06-11)
      — 32 mac_tile macros pin-on-pin at exact 46.656 µm pitch, zero gap,
      **no row CTS**: clock enters tile 0 once and travels the chain
      (+82.34 ps/tile, STA-visible through all 32 tiles). Signoff: setup
      **+180 ps** / hold **+48 ps** @ 250 MHz, 0 setup/hold violations,
      **DRC clean across all 31 abutted boundaries**, 71,984 µm² @ 83%.
      `flow/check_abutment.py` machine-verifies the TILE_SPEC invariants
      (exact-grid, 1271 pin pairs edge-contact, pitch-integral outline).
      Tile resized 46.656×47.52 (track-pitch quanta, TILE_SPEC §1) + rev B
      wave matching (`set_min_delay 85` on feedthroughs). Registered drain
      in RTL (+ STORE write-back stage), 94 tests bit-exact. The
      false-clean trap (falling_edge clk arc → 31 tiles unconstrained) is
      patched + documented; full story in docs/HARDENING.md
- [ ] (7c prep) automate the lib patch inside the BLOCKS flow; per-tile
      clock-arrival table in the report as a standing honesty check
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
