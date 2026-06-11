# PtahCore — Hardening Log (ASAP7 7nm)

Real place-and-route results, recorded honestly as each block closes.
**No masked hold violations, no negative slack margins** (see
docs/INVARIANTS.md §B4). If a block doesn't close, that's recorded too.

## Flow

OpenROAD-flow-scripts (ORFS) on the ASAP7 predictive PDK, driven by
`flow/harden.sh`:

```bash
# one-time: pull the flow image (WSL2 / Docker-Desktop needs a clean
# credential-helper-free config)
mkdir -p /tmp/dockercfg && echo '{}' > /tmp/dockercfg/config.json
DOCKER_CONFIG=/tmp/dockercfg docker pull openroad/orfs:latest

# harden a block
flow/harden.sh mac_cell
```

Design configs live in `flow/designs/asap7/<block>/`:
- `config.mk` — RTL list, platform, floorplan/utilisation
- `constraint.sdc` — clock + I/O timing (250 MHz target)

## Build order (per docs/TILE_SPEC.md)

1. **`mac_cell` tile** — the leaf abutted 1,024×. Must close timing, pass
   DRC, and present the abutment boundary contract.
2. **1×N row** — cells abutted with the traveling clock.
3. **32×32 array** — full grid via row abutment.
4. **`chip_top`** — array + control/memory/engine macros.

## Results

| Block | Status | Clock | Worst setup slack | Worst hold slack | Area | Util | Notes |
|-------|--------|-------|------------|------------|------|------|-------|
| `mac_cell` (pipelined mul \| add) | ✅ **GDS complete** | 250 MHz (4000 ps) | **+1928 ps** | **+13 ps** | **750 µm²** | 44% | signoff: 0 setup / 0 hold / 0 slew / 0 cap / 0 fanout violations, **DRC clean**; crit path ~2.07 ns → ~480 MHz capable |
| row (1×32, hierarchical) | ✅ **GDS complete** | 250 MHz (4000 ps) | **+386 ps** | **+438 ps** | **66,284 µm²** | 56% | 32 `mac_cell` hard macros (BLOCKS flow) + drain mux/broadcast stdcells; 0 setup / 0 hold / 0 cap / 0 fanout, **DRC clean**; ⚠ 3 max-slew pins ≤39 ps over the 320 ps lib limit (see below — recorded, not waived) |
| row (1×N, traveling clock) | ⬜ | — | — | — | — | — | Phase 7b |
| array (32×32) | ⬜ | — | — | — | — | — | — |
| `chip_top` | ⬜ | — | — | — | — | — | — |

_(Pre-layout generic-gate area baselines are in docs/SYNTHESIS.md.)_

## First GDS — `mac_cell` on ASAP7

Full RTL→GDSII, signoff clean, on a laptop under WSL2:

![mac_cell routed layout](img/mac_cell_gds.webp)

*Routed `mac_cell` macro — 750 µm² @ 44% utilisation, ASAP7 7nm predictive
PDK. Clock tree below (17 buffers, 2-level H-tree, 164 sinks):*

![mac_cell clock tree](img/mac_cell_clock_tree.webp)

The GDS itself (`flow/results/asap7/mac_cell/base/6_final.gds`) is a build
artifact — regenerate with `flow/harden.sh mac_cell` (~6 min).

### ⚠️ The picosecond units bug — and what actually happened

The mac_cell **closes 250 MHz setup with ~2 ns margin.** Getting there took a
detour worth recording honestly:

1. **Phase 6a** first P&R reported "WNS −2237 ps, fails 250 MHz." **This was a
   units bug.** ASAP7 SDC time is in **picoseconds** (the platform's own
   examples use `set clk_period 310`). My `set clk_period 4.0` meant **4 ps =
   250 GHz**, so of course everything "violated" — and the negative "ps" values
   were literally the real path delays: ~2.24 ns combinational.
2. **Phase 6b** pipelined the MAC (split multiply | add) — genuinely good design
   that cut the critical path and kept all 89 tests bit-exact — but still read
   the clock as 4 ps, so it looked like it "still failed at −1309 ps." I even
   chased a phantom "the adder can't be pipelined" conclusion.
3. **Phase 6c** found the bug: `4.0` → `4000` ps. With the correct clock the
   pipelined mac_cell closes 250 MHz setup at **+1994 ps slack**, critical path
   ~2.0 ns (≈ 500 MHz capable), 675 µm².

**Lessons kept:** always check the platform's SDC time unit; the pipelined MAC
is still the design we ship (more margin, ~500 MHz headroom, bit-exact). The
accumulate add is a loop-carried dependency and *would* be the floor if it were
the long pole — it isn't here (the multiply is, at ~2 ns), but a Kulisch
fixed-point accumulator remains the right move if we ever push past ~500 MHz.

### Hold — closed with real positive margin

CTS-stage `repair_timing` inserts hold buffers. With the default
`HOLD_SLACK_MARGIN = 0` it repairs to *exactly* zero slack — and post-route
RC then pushed 2 paths to **−1.11 ps**. The honest fix is the **opposite**
of autogpu's masking (they set the margin *negative* to hide violations,
INVARIANTS §B4): we set `HOLD_SLACK_MARGIN = 15` so repair demands +15 ps
of real slack at CTS, absorbing post-route RC pessimism. Final signoff:
**0 hold violations, worst hold slack +13.01 ps.**

<details><summary>Historical Phase 6b notes (pre-correction — kept for the record)</summary>

Pipelined the MAC: split multiply ↔ add, and (briefly) pipelined `fp32_mul`
internally. Reverted the internal-mul split — registering the raw product
dragged the mul's normalize into the add stage and measured worse than
registering the full product. Final design: combinational `fp32_mul`, register
its full output, combinational accumulate add. The pre-correction analysis
below read the clock as 4 ps and is superseded by the section above.

</details>

ASAP7 is a *predictive, deliberately pessimistic* PDK; the ns figures are
relative-honest, not a foundry guarantee — but the closure discipline is the
same either way.

## Second GDS — the 1×32 row (first hierarchical build, Phase 7a)

The Phase-6 `mac_cell` GDS becomes a **hard macro** (ORFS `BLOCKS` flow
auto-hardens it and consumes its LEF/.lib abstract), and the row top is just
the A-broadcast wiring, control fan-out, and the 32:1 drain mux. 1560×80 µm
die, macros on a deterministic 48.625 µm pitch (`macro_place.tcl`).

![mac_row routed layout](img/mac_row_gds.webp)

*Routed 1×32 row — 32 abutment-pitch `mac_cell` macros, ASAP7. Clock below
(row-level CTS for 7a; the traveling clock replaces it in 7b):*

![mac_row clock tree](img/mac_row_clock_tree.webp)

Signoff: **setup +386 ps / hold +438 ps @ 250 MHz, 0 setup / 0 hold / 0 cap /
0 fanout violations, DRC clean**, 66,284 µm² @ 56% util.

### The virtual-clock/propagated-clock trap (the row's units-bug moment)

A block's I/O must be timed against a **virtual clock carrying the launch
latency of the parent's flops** — they sit on the same tree, so timing I/O
against the ideal clock manufactures ~1 ns of phantom *hold* violation into
every macro data pin (first run: hold repair hit its buffer cap at 1564
buffers, worst −669 ps, flow dead at CTS). The subtle part: the latency was
already modeled, but as **plain (network) `set_clock_latency`** — and ORFS
runs `set_propagated_clock [all_clocks]` after CTS, after which **OpenSTA
discards network latency**, silently reverting vclk to ideal. The fix is
`set_clock_latency -source`, which survives propagation. The slack math
confirmed it to the picosecond: 600 io − 150 src − ~990 tree − 29 lib hold
− 100 unc ≈ −669.

### The honesty check, exercised

The SDC required the modeled vclk latency to match post-route reality. First
model: 1150 ps; measured capture latency at the far macro: ~710 ps. The model
was **tightened to 750 ps and re-run** — checking hold ~400 ps *harder* —
and the row still closed (+438 ps worst hold). Models follow silicon, not
the other way around.

### The 3 residual max-slew pins — recorded, not waived

Three stdcell input pins on row-top mux/buffer nets read 330–359 ps against
the 320 ps lib `max_transition` (≤12% over). Root cause: `repair_design`
works from global-route RC estimates, and detailed route eroded a few
buffer-to-gate hops ~115 ps beyond them. `SLEW_MARGIN` was raised 10% → 20%
→ 30% (violators: 8 → 3 → 3, worst −58 → −51 → −39 ps); the knob saturated —
each run just shuffles which nets lose the detour lottery. The timer uses
the *actual* slews, so the +386/+438 slack already absorbs them; the
remaining risk is lib-extrapolation accuracy on 3 arcs, not function. The
row top's routing is redone in 7b (traveling clock + true edge abutment),
which is where these die for real.

## Failure log

Every distinct flow error hit, with root cause + fix, so it's never
re-debugged from scratch.

| Error / symptom | Block | Root cause | Fix |
|-----------------|-------|-----------|-----|
| "fails 250 MHz, WNS −2237 ps" | mac_cell | **ASAP7 SDC time is in picoseconds** — `set clk_period 4.0` = 4 ps (250 GHz), so everything "violated" by its real path delay | use ps: `set clk_period 4000`; design closes with +1994 ps |
| `read_verilog`: "File `SYNTHESIS' not found" | mac_cell | ORFS default Yosys frontend needs `-D` prefix on defines | `VERILOG_DEFINES = -DSYNTHESIS` (not `SYNTHESIS`) |
| SDC: `invalid command name "remove_from_collection"` | mac_cell | OpenROAD's SDC reader lacks `remove_from_collection` | list data ports explicitly in `set_input_delay` |
| `cts.tcl: child killed: illegal instruction` (SIGILL) | mac_cell | **NOT TritonCTS** (initial diagnosis was wrong — CTS + hold repair had already completed in the log). The crash is `run_lec_test` exec-ing the image's `kepler-formal` LEC binary, which uses an instruction this host lacks (i7-9750H has AVX2 but no AVX-512) | `export LEC_CHECK = 0` in config.mk. LEC is an optional post-repair equivalence check; netlist-vs-RTL equivalence is covered by the bit-exact cocotb suite. CTS→route→GDS proceed normally. |
| 2 hold violations post-route, worst −1.11 ps | mac_cell | `HOLD_SLACK_MARGIN` defaults to 0 → CTS hold repair fixes to exactly zero slack, then detailed-route RC pushes marginal paths slightly negative | `export HOLD_SLACK_MARGIN = 15` (a **positive** margin — real extra slack, not masking). Signoff: 0 hold violations, worst +13.01 ps |
| CTS hold repair dies at buffer cap (RSZ-0060), worst −669 ps on every macro data pin | mac_row | vclk launch latency was plain (network) `set_clock_latency`; ORFS `set_propagated_clock [all_clocks]` post-CTS makes OpenSTA discard it → vclk silently ideal → phantom hold wall | `set_clock_latency -source` on the virtual clock — source latency survives propagation |
| setup 0 → −70 ps and 8 slew violations appear only after detailed route | mac_row | repair stages work from global-route RC; detailed-route detours erode the margin they closed to | `SETUP_SLACK_MARGIN = 100`, `SLEW_MARGIN = 30` — repair banks real margin pre-route (same honest pattern as the hold margin) |
| `DPL-0036` detailed placement fails to legalize 1 buffer | mac_row | margin-driven rebuffering outgrew the stdcell strip of the 1560×70 die (macro+halo eats ~47 µm) | die height 70 → 80 µm |
| `MPL-0003` "no valid tilings for mixed cluster" | mac_row | `rtl_macro_placer` heuristics can't tile a 1×32 mixed cluster at 19.5:1 aspect ratio | deterministic `place_macro` script (`MACRO_PLACEMENT_TCL`) — the row layout is fully determined anyway; note ODB instance names keep Yosys escapes: `col\[0\].u_cell` |
| detailed route never converges (466 stuck violations), then OOM | mac_row | macros placed flush against the core's south edge → no routing channel below the macro pins | center the macro row vertically (y = 16.2 µm = 60 site rows) — channels both sides; DRC clean afterwards |
| detailed route OOM at ~7.2 GB (make error 247) | mac_row | OpenROAD defaults to all 12 threads; WSL2 VM has 7 GB | `ORFS_MAKE_ARGS='NUM_CORES=6'` passthrough added to `flow/harden.sh` (ORFS: `OPENROAD_ARGS = -threads $(NUM_CORES)`) |
| 3 max-slew pins survive `SLEW_MARGIN = 30`, worst −39 ps | mac_row | global-route vs detailed-route RC mismatch on individual buffer hops (~115 ps) exceeds any practical uniform margin | **recorded, not waived** — slacks already include the real slews; row top is re-laid-out in 7b |
