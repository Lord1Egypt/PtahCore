# PtahCore — mac_tile hardened as a BLOCK of the abutted row.
#
# Same design as ../../mac_tile/config.mk; only the nickname differs so
# the parent's BLOCKS rule finds the abstract at
# results/asap7/mac_row_abut_mac_tile/<variant>/mac_tile.{lef,_typ.lib}.
# (Layer split M1–M5 and the BLOCK PDN grid are already in the base.)

include $(PTAHCORE)/flow/designs/asap7/mac_tile/config.mk

export DESIGN_NICKNAME = mac_row_abut_mac_tile
