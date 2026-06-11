# PtahCore — ASAP7 config for the ABUTTED traveling-clock row (Phase 7b-3).
#
# Same mac_row netlist as the 7a hierarchical build, but the tiles are
# the 7b-2 mac_tile macros placed at exactly the tile width: pins abut
# coordinate-on-coordinate, the parent routes nothing over tiles, and the
# clock enters tile 0 once and travels the chain through each tile's
# clk_in→clk_out feedthrough instead of a row CTS. The only parent logic
# is the drain_idx mux in the stdcell strip south of the tiles.
#
# Run: ORFS_MAKE_ARGS='NUM_CORES=6' flow/harden.sh mac_row_abut

export DESIGN_NICKNAME = mac_row_abut
export DESIGN_NAME     = mac_row
export PLATFORM        = asap7

export BLOCKS = mac_tile

# Row top only — mac_tile enters as a hard macro via BLOCKS.
export VERILOG_FILES   = $(PTAHCORE)/rtl/mac_row.sv
export VERILOG_DEFINES = -DSYNTHESIS

export SDC_FILE = $(PTAHCORE)/flow/designs/asap7/mac_row_abut/constraint.sdc

# Floorplan, site- and track-aligned (tiles are 46.656 × 47.52 — see the
# tile config for the lcm story):
#   die 1497.312 × 62.64 = 27728 sites × 232 rows
#   tiles y 12.96 … 60.48 (flush with core top); 40-row stdcell strip
#   below the tiles for the drain mux. Core-to-die spacing 2.16 µm all
#   around — the BLOCKS PDN rings need ~1.7×1.6 µm of it (PDN-0351 at
#   1.08 µm spacing).
export DIE_AREA  = 0 0 1497.312 62.64
export CORE_AREA = 2.16 2.16 1495.152 60.48
export MACRO_PLACEMENT_TCL = $(PTAHCORE)/flow/designs/asap7/mac_row_abut/macro_place.tcl
# Zero halo: tiles abut with no stdcells (or anything else) between them.
export MACRO_PLACE_HALO = 0 0
export PLACE_DENSITY = 0.30

# Design-local PDN strategy: stock BLOCKS_grid_strategy with the
# ElementGrid halo hardcoded to 0. The platform wires BOTH the row
# cutting and the macro-PDN halo to MACRO_ROWS_HALO_X/Y, but abutment
# needs them split: rows must stay cut ~2 µm clear of the tiles (halo 0
# leaves an unrepairable M2 rail sliver under the tile edge, PDN-0179),
# while the per-tile PDN grids must NOT overlap their abutted neighbours
# (halo 2 makes pdngen silently skip all pin connects → PSM-0069
# unconnected VDD on every tile). Verified with check_power_grid: all
# VDD/VSS shapes connected, no channel errors.
export PDN_TCL = $(PTAHCORE)/flow/designs/asap7/mac_row_abut/pdn.tcl

# The row top is ~250 µm² of drain-mux stdcells in a 71,000 µm² macro
# sea; RePlAce's routability+timing inflation modes diverge to Inf/NaN
# at that density (GPL-0305). Plain global placement is trivially
# sufficient for 800 cells.
export GPL_ROUTABILITY_DRIVEN = 0
export GPL_TIMING_DRIVEN = 0

# kepler-formal LEC needs AVX-512 this host lacks; equivalence is covered
# by the bit-exact cocotb suite.
export LEC_CHECK = 0
export HOLD_SLACK_MARGIN = 15

# Pre-bank post-route RC erosion at the repair stages (proven on the 7a
# row: detailed route eats margin global-route repair closed to).
export SETUP_SLACK_MARGIN = 100
export SLEW_MARGIN = 30
