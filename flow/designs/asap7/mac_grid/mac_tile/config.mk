# PtahCore — mac_tile hardened as a BLOCK of the 32×32 grid.
#
# Same design as ../../mac_tile/config.mk; only the nickname differs so
# the parent's BLOCKS rule finds the abstract at
# results/asap7/mac_grid_mac_tile/<variant>/mac_tile.{lef,_typ.lib}.

include $(PTAHCORE)/flow/designs/asap7/mac_tile/config.mk

export DESIGN_NICKNAME = mac_grid_mac_tile
