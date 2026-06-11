# PtahCore — ASAP7 hardening config for the 1×32 mac_row.
#
# First hierarchical build (Phase 7a): the Phase-6 mac_cell GDS becomes a
# hard macro (BLOCKS flow auto-hardens it and consumes its LEF/.lib
# abstract), and the row top is just the broadcast wiring + drain mux.
# True edge-pin abutment + the traveling clock are Phase 7b — this pass
# establishes honest hierarchical timing with normal row-level CTS.
#
# Run: flow/harden.sh mac_row

export DESIGN_NICKNAME = mac_row
export DESIGN_NAME     = mac_row
export PLATFORM        = asap7

export BLOCKS = mac_cell

# Row top only — mac_cell enters as a hard macro via BLOCKS.
export VERILOG_FILES   = $(PTAHCORE)/rtl/mac_row.sv
export VERILOG_DEFINES = -DSYNTHESIS

export SDC_FILE = $(PTAHCORE)/flow/designs/asap7/mac_row/constraint.sdc

# Floorplan: 32 mac_cell macros (45.317 µm square, from the Phase-6 DEF)
# in a single row plus a stdcell strip for the drain mux and broadcast
# buffering. Die height only fits one macro row, so placement is
# constrained to the row shape by construction. Height 80 (not 70): the
# macro+halo leaves ~47 µm; at 70 the leftover strip was too tight for
# the margin-driven rebuffering and detailed placement failed to
# legalize a buffer (DPL-0036 on wire9082).
export DIE_AREA  = 0 0 1560 80
export CORE_AREA = 2 2 1558 78
export MACRO_PLACE_HALO = 1 1
export PLACE_DENSITY = 0.40

# Deterministic 1×32 placement; rtl_macro_placer has no valid tiling for
# this aspect ratio (MPL-0003) and the row layout is fully determined.
export MACRO_PLACEMENT_TCL = $(PTAHCORE)/flow/designs/asap7/mac_row/macro_place.tcl

export PDN_TCL = $(PLATFORM_DIR)/openRoad/pdn/BLOCKS_grid_strategy.tcl

# kepler-formal LEC binary needs AVX-512 this host lacks (see mac_cell
# config); equivalence is covered by the bit-exact cocotb suite.
export LEC_CHECK = 0
export HOLD_SLACK_MARGIN = 15

# Post-detailed-route RC eroded what global-route repair had closed:
# setup went 0 → −70 ps on the far-cell A-broadcast endpoints, and 8
# buffer pins on the same nets went over the 320 ps slew limit by up to
# 25 ps. Same honest pattern as the cell's hold margin: demand REAL
# extra margin at the repair stages so route pessimism lands positive.
export SETUP_SLACK_MARGIN = 100
# 30%: detailed-route RC on a few buffer-to-gate hops erodes slew far
# beyond the global-route estimate repair works from (~115 ps observed:
# 10% margin left 8 violators, 20% left 3, worst 371 ps vs the 320 ps
# limit). 30% targets 224 ps at repair to land everything under 320.
export SLEW_MARGIN = 30
