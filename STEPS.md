# PtahCore — Execution Steps

Working checklist. Tick items via PR. Companion to [PLAN.md](PLAN.md).

> **▶ RESUME HERE (as of 2026-06-13 ~02:45, Phase 7d-3 IN PROGRESS,
> branch `feat/phase7d3-chip-flow`, pushed through commit 1eb499e +
> uncommitted GPL/DPL knobs in config.mk):** the chip flow now runs
> SYNTH → FLOORPLAN → PDN → GLOBAL PLACE → DETAIL PLACE clean. Each
> battle + fix is in docs/HARDENING.md (synth OOM=barrel shifters;
> MPL-0034 %g precision; MPL-0020 braced names; PDN-0006 honest grid
> abstract; PDN-0232/0233 design-local pdn.tcl; GPL runaway → timing/
> routability driven OFF; DPL-0036 → -max_displacement 50).
>
 **▶ STATUS 2026-06-14 ~05:30 — DPL is the live blocker; the launch-
> clock fix (RTL buffers + 64 generated clocks) is BUILT + parses but
> DPL won't legalize on this 7.7 GB machine. Repo is at the MEMORY-SAFE
> TIGHT die (1674×1583). Latest pushed: 02476de was the wide-die attempt
> (REVERTED in working tree — re-commit the tight die). The launch fix
> commits (ac4a0d3 buffers+gen_constraints, d43104f tap-driver) stand.**
>
> **The DPL saga, fully mapped (don't re-walk it):** after adding the 64
> launch-tap buffers (chip_top.sv lw_drv/lb_drv) + the 64-generated-clock
> SDC, detailed placement (3_5) cannot legalize 1 repair buffer that
> global-place drops loosely INSIDE the grid macro. Two DISTINCT walls,
> do not confuse: (1) **CPU degeneration** — `-max_displacement` ≥170
> makes the diamond search explore too many sites → 100% CPU, hours, no
> progress (150 finishes-but-fails-by-1; the finish/degenerate cliff is
> ~150–170, razor thin). (2) **MEMORY thrash** — widening the strips to
> give the buffer room (W_STRIP 220) grew the die enough that the full
> chip + 64-clock timing setup blew past 7.7 GB RAM → DPL at 11% CPU
> swap-thrashing (RAM 7.6/7.9 G, +6.4 G swap). **The wide die can't fit
> this flow on this machine — keep the die tight.** So neither lever
> alone works: tight+small-disp strands 1 cell; tight+big-disp CPU-
> degenerates; wide die memory-thrashes.
>
> **NEXT — solve the 1 stranded buffer WITHOUT die area or big
> displacement (tight die, memory-safe). Candidates, try in order:**
> (a) **why is a stdcell loosely placed 146 µm INSIDE a hard macro?** —
> GPL_ROUTABILITY/TIMING_DRIVEN=0 (set for the array) may let global
> place nudge cells onto the grid; try a bigger `MACRO_PLACE_HALO`
> (2→8) or a placement blockage over the grid so GP never seeds cells
> there. (b) reduce the repair buffers that strand — the cell is a
> repair_design (3_4) BUFx16f on net6322/6323 (fanout 2); lower
> `SETUP_SLACK_MARGIN` 100→0 (rely on post-route repair) so fewer
> pre-route buffers are inserted. (c) ORFS `improve_placement`/DPO or a
> targeted region for that one net. **Iterate FAST: the 1.9 h repair
> (3_4) is the bottleneck — keep a cached 3_4 and re-run only 3_5 via
> command-line DETAIL_PLACEMENT_ARGS; only bust the cache (config.mk/
> SDC edit) when changing synth/floorplan.** A bigger-RAM host (≥16 G)
> would also just let the wide die through — worth noting to the user.
>
> *(earlier 2026-06-13 status:)* flow ran clean SYNTH→…→DETAIL-PLACE;
> CTS half-solved: the clk_s tap-driver fix WORKS (CTS trees clk_s_tap →
> 13-buf H-tree, no ODB-037x). The stage-B launch-clock fork is the fix
> now built (RTL buffers + generated clocks) but unverified past DPL.
>
> **▶ THE STAGE-B LAUNCH-CLOCK FORK (chosen path: SDC latency model):**
> post-CTS hold repair dies (RSZ-0060) on `launch_b[*].b_q[*]` /
> `launch_w[*]` — stage-B launch banks on the un-buffered `wtap`/`ntap`
> spine taps, −98 ns RC PHANTOM. VALIDATED real slack is fine: offline
> STA on 3_place (propagated) = hold −1285 ps, the −98 ns appears only
> post-CTS when clk_s is treed (small delay) and the stagger taps keep
> their huge estimate_parasitics RC. CANNOT tree the taps: `wtap` is
> SHARED (clk_row_v grid row clocks need the +82 ps/row stagger;
> clk_lw_v launch), and stage B feeds the grid's `b_n_flat` captured by
> the grid's internal staggered column clock → zero-skew CTS breaks the
> grid lib arcs.
> **WHAT I LEARNED probing the SDC fix (2026-06-13):** (1) standalone
> `clock_tree_synthesis` SEGFAULTs offline — needs ORFS's CTS_BUF_LIST
> env (inferClockBufferList); can't reproduce post-CTS offline that
> way. (2) **A plain `set_clock_latency` on a pin under a PROPAGATED
> clock does NOT reliably override the propagated network RC** — that's
> why the grid used INPUT-PORT clocks with `set_clock_latency -source`.
> So the chip fix is NOT pin latency; it is: define the stagger taps as
> **generated clocks** (`create_generated_clock -source clk_spine` at
> each launch/grid tap) with modeled `-source` latency (δs·i / δe·j from
> ARRAY_SPEC), and do NOT propagate THEM (propagate only `clk` + the
> treed `clk_s_tap`). This is the chip analog of mac_grid's
> gen_constraints.py — BUILD `flow/designs/asap7/chip_top/
> gen_constraints.py` to emit them. clk_s STAYS treed (806-fanout needs
> real distribution); only the low-fanout stagger taps get modeled.
> **NEXT CONCRETE STEP:** write that generator → it emits a constraint
> block (generated clocks + source latencies + NOT-propagated) appended
> to constraint.sdc; then full re-harden (SDC change busts cache →
> from synth ~50 min + 1.9 h repair; budget a long run). If generated
> clocks still fight CTS/the grid arcs, fall back to placement
> clustering (cluster each launch group at its grid edge via DEF
> regions). Fast-STA: /tmp/sta_hold.tcl + /tmp/sta_spine.tcl;
> /tmp/validate_lat.tcl is the (CTS-segfaulting) repro attempt.
>
> *(history: the clk_s blocker —)* CTS died because **`clk_s_tap`, the
> stage-A launch clock, fans out to 806 registers chip-wide on ONE
> unbuffered net**.
> The −149/−152 ns slack in 4_1_cts.log was a PHANTOM (that net's RC
> under estimate_parasitics); offline STA on 3_place.odb (propagated)
> shows REAL slack **setup −1255 / hold −1329 ps** — ordinary. CTS could
> not tree clk_s_tap because post-flatten a bare spine tap net IS the
> dont_touch spine net (`u_spine_w.seg[22].n[1]` → ODB-0370 unscoped /
> ODB-0373 when treed / RSZ-3006 from −repair_clock_nets / RSZ-0060 hold
> repair chasing the phantom).
> **THE FIX (applied this session):**
>   1. `rtl/chip_top.sv` — `u_clk_s_drv` (ptah_clkbuf) isolates a fresh
>      `clk_s_tap` net from the spine so CTS can tree below it (wire in
>      sim → bit-exact, 3/3 chip TB green). Per-row/col wtap/ntap taps
>      LEFT un-buffered on purpose — they are the traveling-clock phases.
>   2. `constraint.sdc` — dont_touch cells matched by `name =~ *u_spine_*`
>      (NOT `ref_name == BUFx24`, which also froze u_clk_s_drv + CTS's
>      own buffers). Only the backbone chains stay sacred.
>   3. `chip_top/config.mk` — `CTS_ARGS = -sink_clustering_enable
>      -clk_nets {clk clk_s_tap}` (drops −repair_clock_nets, the RSZ-3006
>      cause); also persisted GPL off + `DETAIL_PLACEMENT_ARGS
>      = -max_displacement 50` from the earlier place battles.
> RTL changed ⇒ FULL re-harden from synth (log /tmp/chip_flow.log,
> `DOCKER_CONFIG=/tmp/dockercfg ORFS_MAKE_ARGS="NUM_CORES=6"
> flow/harden_chip.sh`). **If CTS still phantoms on the per-row/col taps,
> buffer those too (same u_clk_s_drv pattern) — but they're localized
> ~41-fanout so likely fine.** Fast-STA recipe: /tmp/sta_hold.tcl +
> /tmp/sta_spine.tcl (4 LEFs + odb + NLDM TT + fakeram + patched grid
> lib + sdc + estimate_parasitics + set_propagated_clock).
> **Once CTS passes:** route → 6_final GDS (the SIXTH), then the honesty
> tables (spine-tap arrivals ~85 ps/tap; per-pin launch-phase vs grid
> lib arcs), check_abutment, render, PR. check_power_grid is
> recorded-not-verified (won't fit 7.7 GB VM — needs ≥16 GB).
>
> *(synth-smoke checkpoint removed — synth solved; grid macro artifacts
> must exist at flow/results/asap7/mac_grid/base/, harden_grid.sh
> rebuilds them.)*
>
> *(previous checkpoint, Phase 7c complete:)*
> Phases 0–7c done — **FIVE GDS out**, and the headline is the
> **32×32 ABUTTED ARRAY**: 1024 mac_tile macros pin-on-pin, no array
> CTS, the clock traveling +82.35 ps/col east and +85 ps/row south,
> STA-visible post-route corner to corner (+152 ps → +5,340 ps).
> Signoff @ 250 MHz, routed SPEF: setup **+1156 ps** / hold **+435 ps**,
> TNS 0 both, 0 setup/hold/cap/fanout violations, **DRC clean**,
> 2,270,706 µm² @ 99%, ⚠ 1 max-slew pin +5.13 ps recorded-not-waived.
> `check_abutment.py`: 1024 tiles exact-grid, 104,160 pin pairs
> coordinate-exact. `report_clock_table.py`: monotonic both axes.
> Full RTL→GDSII ≈ 33 min (6 threads, 16 GB swap — GRT peaks ~11.6 GB).
> Build: `DOCKER_CONFIG=/tmp/dockercfg ORFS_MAKE_ARGS="NUM_CORES=6"
> flow/harden_grid.sh` (block → abstract → clk-arc patch → grid; the
> patch step is MANDATORY, see HARDENING.md false-clean trap).
> This phase's traps (all in docs/HARDENING.md failure log): GRT OOM →
> 16 GB swap; **port-buffer trap** → `DONT_BUFFER_PORTS=1` +
> set_driving_cell contracts; **STA readout trap** → report_worst_slack
> first (report_checks shows one path per clock group — 33 here).
> **Score: 95 tests green (58 RTL + 37 Python), 19 PRs merged.**
> **Next — Phase 7d:** `chip_top` GDS — array + cmdproc/smem/barrier/
> load/store macros, the traveling clock + port drivers (BUFx4/BUFx24
> contracts) implemented physically at chip level. Then 7e: GDS web
> viewer.
> Re-verify RTL: `cd rtl/tb && make all_leaves`; `pytest golden pymodel -q`.

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
- [x] (7c prep) lib patch automated in `flow/harden_grid.sh` (block →
      abstract → patch → grid); `flow/report_clock_table.py` is the
      standing per-tile clock-arrival honesty check (2D, both axes)
- [x] **Phase 7c: 32×32 ABUTTED ARRAY — fifth GDS** (2026-06-12) —
      **1024 mac_tile macros pin-on-pin, no array CTS**: clock travels
      +82.35 ps/col east and +85 ps/row south (the spine contract),
      both waves STA-visible post-route corner to corner (+152 ps at
      tile (0,0) → +5,340 ps at (31,31)). Signoff @ 250 MHz, routed
      SPEF: setup **+1156 ps** / hold **+435 ps**, TNS 0 both,
      0 setup/hold/cap/fanout violations, **DRC clean**, 2,270,706 µm²
      @ 99%; 1 max-slew pin +5.13 ps over recorded-not-waived.
      `check_abutment.py`: 1024 tiles exact-grid, **104,160 abutted pin
      pairs coordinate-exact**. Hold is positive by construction
      (per-bit pre-delay contracts + early spine tap, gen_constraints.py)
      with ZERO repair buffers in the macro sea. Battles won this phase:
      GRT OOM (→16 GB swap), the port-buffer trap (`DONT_BUFFER_PORTS=1`
      + set_driving_cell contracts), the per-clock-group STA readout
      trap — all in docs/HARDENING.md. Full RTL→GDSII ≈ 33 min.
- [x] **Phase 7d-1: physical SMEM** (2026-06-12) — smem_phys.sv: 2
      copies × 8 banks of fakeram7_256x256 (1RW) behind smem's exact
      contract; LOAD beats coalesce to 32-B lines; 1RW collisions stall
      the MMA fetch (rd_stall retry, bit-exact under 40% random stalls)
- [x] **Phase 7d-2: chip traveling clock RTL** (2026-06-12) —
      docs/CHIP_SPEC.md contract; clk_spine.sv west (M+LAG_W taps +
      clk_s early tap) + north (N+LAG_B) spines; TWO-STAGE launch banks
      (stage A on clk_s tap, stage B on per-row/col late taps): the
      pre-delay contracts become launch-clock phases, hold-safe by
      phase with zero min-delay assumptions; store DRAIN_LAT=4. Grid
      abstract VERIFIED: setup+hold arcs per data pin vs every row
      clock (34,021 each), zero falling_edge arcs. 17 RTL units + 37
      Python green; chip e2e through spine+banks+smem_phys bit-exact
- [ ] Phase 7d-3: chip flow design — floorplan (L-strip: west logic +
      SMEM macros + spine, north B strip), BLOCKS = mac_grid +
      fakeram7_256x256, dont_touch the spine, launch-bank placement
      regions, PDN; abstracts chained in the harden script (a later
      `make generate_abstract` re-runs the whole flow)
- [ ] chip_top GDS — **timing closed honestly, zero masked hold violations**
- [ ] 2D/3D layout viewer deployed (GDS → web)

## Phase 8 — HW block scaling (MXFP8) ✅ design+verify (2026-06-14, branch `feat/phase8-mxfp8`)
- [x] **MXFP8 microscaling, OCP MX spec** — each K=32 tile is exactly one MX
      block, so scales are per-row (A: M E8M0 scales) / per-col (B: N E8M0).
      C[i,j] = 2^((ea[i]-127)+(eb[j]-127)) · Σ_k decode(A)·decode(B).
- [x] **golden/mxfp8.py** — bit-exact E8M0 decode + the drain-time
      EXPONENT-ADD + saturate (`_scale_one_bits`): overflow→±inf,
      underflow→±0, E8M0 NaN (X=255)→qNaN, inf/NaN/zero accumulator
      passthroughs. 45 golden tests (scale edges + random matmul vs numpy).
- [x] **pymodel** — `Mma` ISA gains `mx`/`sa_smem`/`sb_smem`; MacArray holds
      per-slot scales, applied at `drain_read`; cmdproc fetches the M+N E8M0
      bytes from SMEM. e2e MX matmul bit-exact vs golden; mx=0 unchanged.
- [x] **RTL** — `mx_scale.sv` (combinational exponent-add+saturate, golden
      twin) on the **drain/store path** (the 1024 MAC cells are untouched);
      `mma_unit` fetches the scales (one extra mx-only read) and holds them
      per-slot, answering store's matched-index lookup at write-back; cmdproc
      decodes the `mx` field (packed in the MMA-unused g32/n32 + bit 140);
      `chip_top` wires it. cocotb twins: `test_mx_scale` (vs golden),
      mma_unit MX fetch/lookup, chip_top e2e MXFP8 — all bit-exact.
- [x] **mx=0 is bit-identical** — full regression green (62→66 RTL cocotb
      tests across 18 units, 37→84 Python tests), latch-check clean. The
      five existing GDS paths are undisturbed.
- [ ] Phase 8 GDS (needs Docker) — re-harden chip_top with the mx_scale
      block on the drain path; sim/verification above is Docker-free and done.

**Note:** the scale lives on the drain/store path, not the MAC array — a tiny
exponent add, no multiply (E8M0 is power-of-two). A real HW constraint
surfaced + documented: scale operands are read as one 32-B `RD_BYTES` line,
so their SMEM base is 32-B aligned and the LOAD DMA writes a full 32-B line
(smem_phys coalesces 16-B beats).

## Phase 9 — 2:4 structured sparsity
- [x] **Phase 9a: format + golden + pymodel** (2026-06-14, branch
      `feat/phase9-sparse24`) — 2:4 sparsity on A along K: every group of 4
      K-lanes keeps 2 nonzeros. Compressed A = M×(K/2) kept fp8 values +
      M×(K/4) metadata (two 2-bit kept-lane indices/group). **golden/
      sparse24.py**: compress/decompress, `matmul_reference_sparse`, the
      contract that a 2:4-sparse matmul == the dense matmul of the
      decompressed A (zero lanes are exact fp32 no-ops, ascending-k order
      preserved). 12 golden tests. **pymodel**: `Mma` gains `sparse`/
      `meta_smem`; MacArray runs **K/2 array steps** with per-row B gather
      by metadata → bit-exact vs golden AND the 2× throughput proven by
      step count. e2e through the Sim bit-exact. `sparse=0` unchanged
      (dense path bit-identical). 98 Python tests green.
- [ ] **Phase 9b: RTL sparse-select datapath + 2× throughput** — the
      invasive part: in the broadcast array, each row's PE must select 2 of
      4 B lanes per group from its OWN metadata (B is broadcast a 4-lane
      group window; each cell muxes). Touches mac_cell/array + mma_unit
      fetch (a_vals + metadata). `sparse=0` must stay bit-identical so the
      five GDS paths are undisturbed (the mx=0 discipline). Then the GDS
      (needs Docker).
  - [x] **9b-i:** `rtl/sparse_select.sv` — the per-cell 2-of-4 lane mux
        (the reusable HW primitive), cocotb twin vs golden (`test_sparse_
        select`), bit-exact. Zero-risk additive module — no hardened path
        touched. `docs/SPARSITY.md` specs the array integration.
  - [x] **9b-ii:** `rtl/mac_array_sparse.sv` — the full 2:4 sparse COMPUTE
        datapath proven in real RTL: per-row a_vals/meta + per-column 4-lane
        B window, a per-cell 2-of-4 mux feeding the **untouched** mac_cell,
        K/2-step sequencing. cocotb (`test_mac_array_sparse`): bit-exact vs
        golden (matmul + accumulate) and the K/2 throughput verified by
        cycle count. Reuses the verified mac_cell leaf and touches **no**
        hardened/abutted module → dense GDS path 100% intact.
  - [ ] **9b-iii (Docker):** fold the per-cell select into the abutted
        traveling-clock array — widen the mac_tile B feedthrough 1→4 lanes +
        route meta_sel, then re-harden. This is the only sparse step that
        changes the physical tile (invalidates the GDS abstracts), so it is
        bundled with the chip re-harden. The RTL datapath + bit-exact
        reference + verified primitive are all in tree to build from
        (mac_array_sparse.sv, sparse_select.sv, docs/SPARSITY.md).

## Phase 10 — Stretch
- [x] **64×64 config build — RTL + model side** (2026-06-14) — proven at
      BOTH layers (they're independent codebases):
  - **model:** `pymodel/tests/test_scale.py` drives the FULL pymodel
    (cmdproc→load→array→store) at 16×16×16, **64×64×64**, 64×32×16
    bit-exact vs golden + MXFP8 at 64×64. (proves the algorithm scales)
  - **RTL elaboration:** `sh synth/lint_64.sh` — `verilator --lint-only`
    of mac_array, mma_unit, **and chip_top at MMA_M=N=K=64**: zero errors
    (catches the width/generate bugs the pymodel can't). (proves the
    Verilog's bit-widths/generates hold at 64)
  - **RTL bit-exact sim:** `make sim TOP=mac_array_big` runs mac_array at
    a non-native **64×4×64** (M and K past the native 32), bit-exact vs
    golden incl. accumulate. (proves the parameterized RTL *functions* at
    a shape it was never built at; N kept small so the cell count stays
    tractable — the 64×64 widths are covered by the lint above)
  - Verified: 102 Python tests, 20 all_leaves RTL units, the standalone
    `mac_array_big` sim, and the 64×64×64 lint — all green. (The 64×64
    **GDS** is a P&R re-run → Docker.)
- [ ] **Multi-shape MMA (M/N/K operand fields return)** — Docker-free RTL
      feature, NOT yet done. A runtime per-MMA shape (M/N/K ≤ native, mask
      the surplus rows/cols/K-steps) touching the ISA (new operand fields),
      cmdproc decode, mma_unit, and array masking. Scoped out this session
      to keep the tree clean; the next Docker-free task. (config-time
      reshape is already proven by test_scale.py; this is *per-instruction*
      shape.)
- [ ] GDS gallery + blog-style writeup — the writeup is Docker-free; the
      gallery images come from the GDS artifacts (Docker).
