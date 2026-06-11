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

# Fixed, site-aligned outline (TILE_SPEC §1: identical across instances,
# multiple of the site grid). 46.44 = 860 × 0.054 µm sites = 172 × 0.27 µm
# rows — integral both ways, so abutted tiles land on-grid by construction.
# Core inset 1.08 (20 sites / 4 rows) per side.
export DIE_AREA  = 0 0 46.44 46.44
export CORE_AREA = 1.08 1.08 45.36 45.36
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
