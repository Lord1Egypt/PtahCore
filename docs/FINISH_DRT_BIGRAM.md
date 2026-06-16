# Finishing the 6th GDS (chip_top) on a ≥24 GB Docker machine

**Why:** every P&R frontier is solved — synth → floorplan → PDN → place →
repair → DPL → CTS → **global route (congestion 0/0/0)** all pass on the
16 GB dev laptop. Only **detail routing (`5_2_route`)** is left, and it needs
**~14 GB** (375k instances × M2–M9 routing graph, hot/unswappable working set).
The laptop tops out at ~13.8 GB usable (Windows needs ~2 GB), so DRT OOMs by a
hair (`anon-rss` 13.3–13.5 GB, still growing). A box with ≥24 GB RAM clears it
in one shot.

## What's already proven (don't re-derive)
- All fixes are committed on branch **`feat/phase7d3-chip-flow`** (commit
  `b008c87`): wide die, `MAX_ROUTING_LAYER=M9`, `pre_global_route.tcl`
  (0.15 GR adjustment + **M8/M9 obstruction over the grid-macro interior** —
  the macro LEF only OBS's M1–M7, so gridding M8/M9 over 83 % of the die was
  pure waste; this cut DRT peak 14.4→13.5 GB), `mx_scale.sv` in `VERILOG_FILES`
  (Phase 8 MXFP8 in the netlist), `DOCKER_MEM_ARGS` knob in `harden_chip.sh`.
- Global route reaches **0/0/0 congestion** with the 50-iteration overflow
  removal (`GLOBAL_ROUTE_ARGS=-verbose` drops `-allow_congestion`).

## Steps on the big machine (Docker + ≥24 GB, Linux/WSL)
```bash
git clone <repo>; cd ptahcore; git checkout feat/phase7d3-chip-flow
docker pull openroad/orfs:latest

# 1) rebuild the grid macro (its artifacts are gitignored) — ~1 h
ORFS_MAKE_ARGS="NUM_CORES=8" flow/harden_grid.sh

# 2) harden the chip end-to-end -> 6_final.gds  (~4-5 h; DRT now fits)
ORFS_MAKE_ARGS='NUM_CORES=8 SKIP_CTS_REPAIR_TIMING=1 SKIP_INCREMENTAL_REPAIR=1 \
  SKIP_ANTENNA_REPAIR=1 \
  PRE_GLOBAL_ROUTE_TCL=/work/flow/designs/asap7/chip_top/pre_global_route.tcl \
  GENERATE_ARTIFACTS_ON_FAILURE=1 GLOBAL_ROUTE_ARGS=-verbose' \
  flow/harden_chip.sh
```
(With ≥24 GB you do NOT need the `DOCKER_MEM_ARGS` swap knob or `NUM_CORES=1`.)

Result: `flow/results/asap7/chip_top/base/6_final.gds`.

## Verify (the honest sign-off — do NOT skip)
- `flow/reports/asap7/chip_top/base/5_route_drc.rpt` is **empty** (DRC clean).
- `6_finish.rpt`: re-check **hold** on the launch→grid paths with the real
  post-route SPEF. The pre-route launch-clock phantom (−47 ns) was an
  `estimate_parasitics` artifact on the un-routed spine and was deliberately
  skipped pre-route (`SKIP_*`); confirm the real routed hold is positive /
  not masked. If genuine hold violations remain, fix them (placement-cluster
  the launch banks / add real delay) — do not waive.

## Shortcut: rent a cloud VM by the hour
A 32 GB cloud instance (AWS `r-`/`m-` class, GCP, Hetzner CPX, etc.) with
Docker installed runs this in ~1 evening for a few dollars. This is **NOT**
Docker's paid "Build Cloud" subscription — just a normal Linux VM with more RAM.
