# PtahCore — mac_cell hardened as a BLOCK of mac_row (hierarchical flow).
#
# Same design as ../../mac_cell/config.mk; what differs:
#  - DESIGN_NICKNAME: the parent's BLOCKS rule looks for the abstract at
#    results/asap7/mac_row_mac_cell/<variant>/mac_cell.{lef,_typ.lib}
#  - PDN: the macro-grade BLOCK grid strategy, so the tile's power pins
#    are connectable from the parent's BLOCKS-level grid.

include $(PTAHCORE)/flow/designs/asap7/mac_cell/config.mk

export DESIGN_NICKNAME = mac_row_mac_cell
export PDN_TCL = $(PLATFORM_DIR)/openRoad/pdn/BLOCK_grid_strategy.tcl

# Tile/parent layer split: the macro keeps M1-M5 (routing + power pins on
# M5), M6-M7 belong to the parent for its straps and row routing. Without
# this the abstract's M6/M7 obstructions block the parent's PDN vias.
export MAX_ROUTING_LAYER = M5
