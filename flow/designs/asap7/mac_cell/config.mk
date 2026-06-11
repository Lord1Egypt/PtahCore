# PtahCore — ASAP7 hardening config for the mac_cell tile.
#
# mac_cell is the leaf that the array stamps M*N = 1024 times, so it is
# the first and most important macro to harden: it must close timing,
# pass DRC, and present a clean abutment boundary (see TILE_SPEC.md) so a
# row of cells can tile edge-to-edge without a chip-wide clock tree.
#
# Run (from inside the ORFS container, ORFS env sourced):
#   make DESIGN_CONFIG=/work/flow/designs/asap7/mac_cell/config.mk

export DESIGN_NICKNAME = mac_cell
export DESIGN_NAME     = mac_cell
export PLATFORM        = asap7

# RTL: the cell + its fp32 arithmetic submodules. SYNTHESIS strips the
# sim-only assertions.
export VERILOG_FILES = \
    $(PTAHCORE)/rtl/fp32_mul.sv \
    $(PTAHCORE)/rtl/fp32_add.sv \
    $(PTAHCORE)/rtl/mac_cell.sv
export VERILOG_DEFINES = -DSYNTHESIS

export SDC_FILE = $(PTAHCORE)/flow/designs/asap7/mac_cell/constraint.sdc

# Floorplan: start utilisation modest — the fp32 multiply is dense; we
# tighten after the first clean pass. Square aspect for easy abutment.
export CORE_UTILIZATION   = 40
export CORE_ASPECT_RATIO  = 1
export CORE_MARGIN        = 2
export PLACE_DENSITY      = 0.55

# ASAP7 is a predictive PDK; keep the default RC corner and metal stack.
# Single-cell macro: no PDN straps needed beyond the standard rails.

# The image's kepler-formal LEC binary SIGILLs on CPUs without AVX-512
# (this host: i7-9750H). It is an optional post-repair equivalence check,
# not part of the flow proper — TritonCTS/route/GDS are unaffected.
# Equivalence is covered by our own bit-exact cocotb suite (89 tests).
export LEC_CHECK = 0

# Repair hold to a POSITIVE margin (ps). With the default 0, repair fixes
# hold to exactly zero at CTS and post-route RC then pushed 2 paths to
# -1.11 ps. +15 ps of real margin absorbs that. This is the opposite of
# masking (negative margin, INVARIANTS B4): we demand MORE than zero slack.
export HOLD_SLACK_MARGIN = 15
