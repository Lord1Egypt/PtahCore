# PtahCore — ASAP7 hardening config for the mac_tile abutment tile.
#
# Phase 7b-2: the tile that actually abuts. Same compute core as the
# Phase-6 mac_cell, plus the TILE_SPEC boundary: every signal pin sits on
# the edge that carries it, west-ins mirror east-outs and north-ins mirror
# south-outs (io.tcl), so a row is assembled pin-on-pin with zero parent
# routing over tiles and the clock travels west→east through the chain.
#
# Run: ORFS_MAKE_ARGS='NUM_CORES=6' flow/harden.sh mac_tile

export DESIGN_NICKNAME = mac_tile
export DESIGN_NAME     = mac_tile
export PLATFORM        = asap7

export VERILOG_FILES = \
    $(PTAHCORE)/rtl/fp32_mul.sv \
    $(PTAHCORE)/rtl/fp32_add.sv \
    $(PTAHCORE)/rtl/mac_cell.sv \
    $(PTAHCORE)/rtl/mac_tile.sv
export VERILOG_DEFINES = -DSYNTHESIS

export SDC_FILE       = $(PTAHCORE)/flow/designs/asap7/mac_tile/constraint.sdc
export IO_CONSTRAINTS = $(PTAHCORE)/flow/designs/asap7/mac_tile/io.tcl

# Fixed outline (TILE_SPEC §1: identical across instances, multiple of
# the site grid AND of every owned routing-track pitch — place_macro
# snaps macros to tracks, so a width that isn't track-integral flips the
# track phase tile-to-tile and zero-gap abutment becomes overlap; the
# first 46.44 µm tile hit exactly that, +24 nm snap = half an M5 pitch).
#   width  46.656 = 108 × 0.432  (0.432 = lcm of site 0.054, M1/M3 0.036,
#                                 M5 0.048 — every vertical pitch)
#   height 47.52  =  22 × 2.16   (2.16 = lcm of row 0.27, M2 0.036,
#                                 M4 0.048 — every horizontal pitch)
export DIE_AREA  = 0 0 46.656 47.52
export CORE_AREA = 1.08 1.08 45.576 46.44
export PLACE_DENSITY = 0.55

# Tile/parent layer split (same as the 7a block): the tile keeps M1–M5,
# M6–M7 belong to the parent row/array for straps. Macro-grade PDN so the
# power pins are connectable from the parent grid (TILE_SPEC §2).
export MAX_ROUTING_LAYER = M5
export PDN_TCL = $(PLATFORM_DIR)/openRoad/pdn/BLOCK_grid_strategy.tcl

# kepler-formal LEC binary needs AVX-512 this host lacks; equivalence is
# covered by the bit-exact cocotb suite (94 tests).
export LEC_CHECK = 0

# Real positive hold margin at repair (NOT masking — see INVARIANTS §B4),
# absorbing post-route RC. Proven on mac_cell and the 7a row.
export HOLD_SLACK_MARGIN = 15
