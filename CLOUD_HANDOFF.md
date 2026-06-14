# PtahCore — Cloud Handoff (resume Phase 7d-3, the full-chip GDS)

> **⚠ UPDATE 2026-06-14 (later):** a Docker-free session then landed
> **Phases 8 (MXFP8), 9a/9b-i/9b-ii (2:4 sparsity), and the Phase-10 64×64
> RTL scalability proof** — all merged into `feat/phase7d3-chip-flow`, all
> bit-exact, `mx=0`/`sparse=0` bit-identical so these GDS notes still hold.
> **Read `docs/RESUME.md` first** — it lists exactly what's done and the
> ordered Docker/P&R steps that remain. This file's flow mechanics below
> are still the accurate P&R reference.

**For: a fresh Claude (or engineer) picking this up on a bigger machine.**
**Written: 2026-06-14, after a long night of P&R on a RAM-limited (7.7 GB) WSL2 box.**

---

## TL;DR — what to do

1. **Verify the environment first** (the whole flow needs Docker):
   ```
   docker info && nproc && free -g && df -h .
   ```
   - Docker **must** work (the OpenROAD/Yosys/KLayout toolchain runs only
     inside the `openroad/orfs:latest` image, ~6.5 GB). No Docker → see
     "If no Docker" below.
   - This machine has **15 GB RAM** (the local one had 7.7 GB). **That is
     the whole reason we moved here** — the chip P&R hit a hard memory wall
     at ~14 GB locally. 15 GB should clear it.
2. **Read `STEPS.md`** → the "▶ STATUS 2026-06-14" resume block has the
   complete live state. Read `docs/HARDENING.md` (bottom failure-log table)
   for every trap already solved — **do not re-debug those.**
3. **Pull the toolchain:** `docker pull openroad/orfs:latest`
   (on Linux cloud you do NOT need the WSL `DOCKER_CONFIG=/tmp/dockercfg`
   credential-helper trick — that was a Windows/Docker-Desktop quirk.)
4. **Rebuild the grid macro** (its artifacts are gitignored — see below):
   ```
   ORFS_MAKE_ARGS="NUM_CORES=4" flow/harden_grid.sh
   ```
   (~1 h. Produces flow/results/asap7/mac_grid/base/{mac_grid.lef,
   mac_grid_typ.lib, 6_final.gds} which chip_top consumes.)
5. **Harden the chip:**
   ```
   ORFS_MAKE_ARGS="NUM_CORES=4" flow/harden_chip.sh
   ```
   With 15 GB RAM you can also try the **wide-die** variant (see "The two
   strategies" below) which is simpler and was only abandoned for memory.

> Set **`NUM_CORES=4`** everywhere (this box has 4 cores; the local
> scripts used 6). Detailed route memory also scales with cores.

---

## What PtahCore is / where we are

Open-source FP8 32×32 systolic matmul accelerator, RTL→7nm GDSII, fully
from scratch (clean-room). Toolchain: Verilator+cocotb (sim), Yosys
(synth), OpenROAD/ORFS + ASAP7 PDK (P&R). Repo:
https://github.com/Lord1Egypt/PtahCore · branch **`feat/phase7d3-chip-flow`**.

**FIVE GDS already out** (Phases 0–7c): mac_cell, 1×32 row, mac_tile,
the abutted traveling-clock row, and the headline **32×32 abutted array**.
Phase **7d-3** is the LAST hardening milestone: turn `chip_top` (the WHOLE
chip — the array macro + 64 KB SMEM as 16 SRAM macros + cmdproc + barrier
+ load + store + the traveling-clock spine) into the **SIXTH GDS**.

Everything past 7d-3 (Phases 7e viewer, 8 block-scaling, 9 sparsity, 10
stretch) is RTL/sim/web work that iterates in **seconds**, not the
multi-hour P&R loops — no special machine needed for those.

**Verify the RTL is still green before hardening** (fast, no Docker):
```
cd rtl/tb && make all_leaves        # 17 units, ~62 cocotb tests, bit-exact
pytest golden pymodel -q            # 37 python tests
```

---

## The flow stages & where it currently dies

`flow/harden_chip.sh` runs OpenROAD's ORFS: synth → floorplan → PDN →
global place → **repair (3_4, ~1.9 h — the slow one)** → detailed place
(3_5) → CTS (4_1) → route (5_*) → finish (6_* = GDS).

**Status on the 7.7 GB box: it gets through synth → floorplan → PDN →
global place → repair every single run, and DIES at detailed placement
(3_5) or CTS (4_1).** The fixes below are all committed; the *last* one
(`67929fd`) should let 3_5 pass — it was launched but the run was stopped
to hand off here.

---

## Problems faced & fixes applied (all committed — chronological)

| Stage | Problem | Fix (commit) |
|-------|---------|--------------|
| synth | 2.5 h OOM at 7.5 GB | Structural: operand byte-select indexed the full 8192-bit latch with a runtime counter → 64× full-width barrel shifters; mma_unit dynamic part-select WRITES → RMW masks. Rewrote as constant-window + narrow mux / per-chunk enable regs. Bit-exact. (earlier, merged) |
| sim | clk_spine false UNOPTFLAT on fresh Verilator | scoped `lint_off UNOPTFLAT` (split_var impossible under cocotb `--public-flat-rw`) |
| floorplan | MPL-0034 (0.002 µm), MPL-0020 (unbraced names) | `%g`→`%.3f`; brace Yosys-escaped macro names |
| PDN | PDN-0006/0232/0233 — ORFS abstract blankets the grid's own M6 power pins | `flow/exact_obs_lef.py` + `exact_abstract.tcl` regenerate an exact-M7 abstract; design-local `pdn.tcl` (M7 straps + GridArray M6↔M7 connect) |
| global place | GPL timing/routability-driven runaway (9 GB swap, stuck) | `GPL_TIMING_DRIVEN=0 GPL_ROUTABILITY_DRIVEN=0` in config.mk |
| **CTS** | clk_s_tap (806-fanout stage-A launch clock) un-treed → −152 ns hold PHANTOM (real slack ~1.3 ns); CTS can't tree a bare spine tap (ODB-0373) | **`u_clk_s_drv` (ptah_clkbuf)** isolates a fresh net; SDC dont_touch narrowed to `*u_spine_*`; `CTS_ARGS=-clk_nets {clk clk_s_tap}`. **CONFIRMED WORKING** — CTS builds the tree. (d43104f, ac4a0d3) |
| **CTS** | Stage-B launch banks (wtap/ntap taps) — same −98 ns phantom, can't be treed (shared with grid row clocks + grid lib arcs) | **64 per-tap buffers** (lw_drv/lb_drv) + `gen_constraints.py` emits **64 NON-propagated generated clocks** with the designed stagger (δs=85, δe=82.34 ps/tap) so STA uses the contract phase, not the phantom RC. (ac4a0d3) — **UNVERIFIED past DPL** |
| **DPL** | DPL-0036: 1 repair buffer stranded inside the grid macro | **ROOT CAUSE: repair_design builds buffer trees for the 32-fanout launch nets → buffers land in the grid.** Fix = `set_dont_touch` on `clk_lw_buf[*]/clk_lb_buf[*]` (they're modeled ideal anyway). **(67929fd — the fix to verify first.)** |
| DPL | displacement tuning is a TRAP | 150 µm finishes-but-fails-by-1; **≥170 µm CPU-degenerates** (diamond search explodes); widening strips → **die too big → memory thrash**. Don't chase displacement. The dont_touch fix removes the need. |

---

## The two strategies (pick based on RAM)

- **Tight die (current repo state, memory-safe):** DIE 1674×1583. The
  `dont_touch` fix (67929fd) should let DPL pass here even at 7.7 GB.
  This is what's committed now. **Try this first** — `flow/harden_chip.sh`
  as-is.
- **Wide die (needs ~15 GB):** widening W_STRIP 172.8→220 gave repair
  buffers room so placement is trivial — but it pushed the die past 7.7 GB
  RAM and thrashed. **On a 15 GB box this just works** and is the simplest
  path. To use it: in `flow/designs/asap7/chip_top/gen_floorplan.py` set
  `W_STRIP = 220.32`, `N_STRIP = 64.8`, run `python3 .../gen_floorplan.py`,
  copy the printed DIE_AREA/CORE_AREA into `config.mk`, then harden.
  (This was committed once as 02476de then reverted for memory — git show
  02476de for the exact diff.)

**Recommendation for a 15 GB box:** try the tight die + dont_touch fix
first (it's already set up); if DPL still strands, switch to the wide die
(the memory headroom makes it the clean solution).

---

## After DPL passes — the real test still ahead

CTS is where the launch-clock model gets verified. Watch for:
- **`report_worst_slack -max/-min` FIRST** (untruncated) — `report_checks`
  prints one path PER CLOCK GROUP and there are 66 clocks here; a
  truncated tail lies. (This trap already cost hours.)
- The −98/−152 ns numbers are PHANTOMS if they reappear; the real slack is
  ~1.3 ns. Offline STA recipe is in `/tmp/sta_hold.tcl` locally (not in
  repo — rebuild from STEPS.md "Fast-STA recipe": read 4 LEFs + the odb +
  NLDM TT libs + fakeram + patched grid lib + the sdc + estimate_parasitics
  + set_propagated_clock).
- **Honesty caveat (in gen_constraints.py header):** the launch clocks are
  modeled as ideal/non-propagated. After route, RE-CHECK the launch paths
  with propagated clocks. If they're genuinely slow (the launch registers
  routed far from their tap), the proper fix is **placement-clustering**
  each launch group at its grid edge (DEF regions) — documented as the
  fallback in STEPS.md. Don't claim closure on the model alone.

When it finishes: GDS at `flow/results/asap7/chip_top/base/6_final.gds`;
run `flow/check_abutment.py` style checks; render via klayout
(`QT_QPA_PLATFORM=offscreen klayout -z -nc -r script.py`, works headless in
the orfs image). Then PR → merge → tick Phase 7d-3 in STEPS.md.

---

## Gotchas / environment notes (don't re-learn these)

- **Grid macro artifacts are gitignored** → a fresh clone MUST run
  `flow/harden_grid.sh` before `flow/harden_chip.sh` (the chip consumes
  mac_grid.lef/.lib/.gds via ADDITIONAL_*). harden_grid.sh also patches the
  tile clk arc (MANDATORY — see HARDENING "false-clean" trap) and builds
  the exact-OBS abstract.
- **ORFS artifacts are root-owned** (Docker) → wipe via Docker, not host
  `rm`: `docker run --rm -v $PWD:/work openroad/orfs:latest bash -c "rm -rf
  /work/flow/results /work/flow/logs /work/flow/reports /work/flow/objects"`.
- **Fast iteration:** the 1.9 h repair stage (3_4) is the bottleneck. Once
  you have a good cached 3_4, iterate ONLY detailed placement via
  command-line `ORFS_MAKE_ARGS="... DETAIL_PLACEMENT_ARGS='-max_displacement
  150'"` — command-line make-vars DON'T bust the stage cache; editing
  config.mk/SDC DOES (re-runs from synth).
- **cocotb 1.x exits 0 on test FAILURES** → `rtl/tb/check_results.py` parses
  results.xml; trust it, not the make exit code.
- SDC time is in **PICOSECONDS** (clk_period 4000 = 250 MHz).
- `LEC_CHECK=0` (the image's kepler-formal LEC needs AVX-512; bit-exact
  cocotb suite covers equivalence). `HOLD_SLACK_MARGIN=15` (positive =
  honest). House style: zero masked hold violations, ever.

---

## If no Docker on the cloud box

P&R is blocked without the ORFS image (a native OpenROAD+Yosys+KLayout+ORFS
install is possible but heavy — hours). BUT the cloud box is still ideal for
the **fast phases that need no Docker**: re-verify RTL (`make all_leaves`,
`pytest`), and do Phases **8 (block scaling)** and **9 (2:4 sparsity)** —
RTL + golden + pymodel work, all bit-exact sim. Only the *new GDS* for those
phases would need Docker; the design+verification doesn't.

---

## State summary

- Branch `feat/phase7d3-chip-flow`, HEAD = `67929fd` (the dont_touch DPL
  fix, launched-but-not-yet-verified locally).
- RTL: 17 units bit-exact, chip_top e2e green (incl. the launch buffers).
- Flow reaches global-place/repair reliably; DPL/CTS are the frontier.
- Full live detail: **`STEPS.md`** ("STATUS 2026-06-14" block) +
  **`docs/HARDENING.md`** (failure-log table).
