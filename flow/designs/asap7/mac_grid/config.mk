# PtahCore — ASAP7 config for the 32×32 ABUTTED ARRAY (Phase 7c).
#
# 1024 mac_tile macros pin-on-pin in BOTH axes (46.656 × 47.52 pitch,
# zero gap), no array CTS: each row's clock enters its west port once
# and travels the tile chain; rows are staggered south by the spine
# contract in constraint.sdc (docs/ARRAY_SPEC.md). The only stdcells
# are the south strip's drain column mux + register.
#
# Run: ORFS_MAKE_ARGS='NUM_CORES=6' flow/harden_grid.sh
# (orchestrates block → abstract → clk-arc patch → grid; the patch step
# is MANDATORY — see docs/HARDENING.md, the false-clean trap.)

export DESIGN_NICKNAME = mac_grid
export DESIGN_NAME     = mac_grid
export PLATFORM        = asap7

export BLOCKS = mac_tile

# Grid top only — mac_tile enters as a hard macro via BLOCKS.
export VERILOG_FILES   = $(PTAHCORE)/rtl/mac_grid.sv
export VERILOG_DEFINES = -DSYNTHESIS

export SDC_FILE = $(PTAHCORE)/flow/designs/asap7/mac_grid/constraint.sdc

# Floorplan (gen_floorplan.py — regenerate macro_place/io_constraints
# after any geometry change):
#   die 1497.312 × 1535.76; core 2.16 2.16 1495.152 1533.60
#   tiles y 12.96 … 1533.60 (row 0 at the TOP — B enters from the north
#   die edge); 10.8 µm (40-row) stdcell strip below row 31 for the
#   drain mux + register. Margins per the 7b-3 PDN-0351 story.
export DIE_AREA  = 0 0 1497.312 1535.76
export CORE_AREA = 2.16 2.16 1495.152 1533.60
export MACRO_PLACEMENT_TCL = $(PTAHCORE)/flow/designs/asap7/mac_grid/macro_place.tcl
export IO_CONSTRAINTS = $(PTAHCORE)/flow/designs/asap7/mac_grid/io_constraints.tcl
# Zero halo: tiles abut with nothing between them (7b-3 contract).
export MACRO_PLACE_HALO = 0 0
export PLACE_DENSITY = 0.30

# Same split-halo PDN strategy as the abutted row (rows cut clear of
# tiles, per-tile PDN grids halo 0 so pin connects aren't skipped —
# PDN-0179 / PSM-0069 in docs/HARDENING.md).
export PDN_TCL = $(PTAHCORE)/flow/designs/asap7/mac_grid/pdn.tcl

# ~250 µm² of drain-mux stdcells in a 2.3 mm² macro sea: RePlAce's
# inflation modes diverge at that density (GPL-0305, 7b-3).
export GPL_ROUTABILITY_DRIVEN = 0
export GPL_TIMING_DRIVEN = 0

# kepler-formal LEC needs AVX-512 this host lacks; equivalence is
# covered by the bit-exact cocotb suite.
export LEC_CHECK = 0
export HOLD_SLACK_MARGIN = 15

# Pre-bank post-route RC erosion at the repair stages (7a lesson).
export SETUP_SLACK_MARGIN = 100
export SLEW_MARGIN = 30

# The congestion-resolution loop in global route exhausts the 7 GB
# WSL2 VM at extra-iteration 3/30 (Error 247, twice) while post-CTS
# timing is already fully closed (+1143/+32, TNS 0). Most of the die is
# abutted pin-on-pin connections with no real routing demand: cap the
# loop below the OOM point and hand the (local) leftover congestion to
# detailed route. (GRT_ALLOW_CONGESTION is not an ORFS variable — the
# knob is GLOBAL_ROUTE_ARGS, found in variables.yaml.)
export GLOBAL_ROUTE_ARGS = -congestion_iterations 2 -allow_congestion -congestion_report_iter_step 1 -verbose
