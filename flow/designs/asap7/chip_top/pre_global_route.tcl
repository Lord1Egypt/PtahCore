# PRE-GLOBAL_ROUTE hook (sourced via PRE_GLOBAL_ROUTE_TCL).
#
# (1) Loosen the platform's 0.25 GR layer-adjustment margin: with the 16 SRAM
#     macros funnelling 4096 dout/wr wires east out of one west column, 0.25
#     left residual congestion even with M8/M9 (GRT-0704 advised reducing it).
set_global_routing_layer_adjustment M2-M9 0.15

# (2) Block M8/M9 OVER THE GRID-MACRO INTERIOR. The mac_grid macro LEF only
#     OBS's M1-M7, so opening M8(H)/M9(V) for the SRAM congestion (which is in
#     the WEST/NORTH STRIPS) also let GR+DRT grid two full layers over the
#     1497x1535 um macro = 83% of the die. Nothing routes over the macro
#     interior (its pins are all on the edges; M1-M7 are already blocked
#     there), so that grid was pure wasted memory -- it pushed DRT's working
#     set past 12 GB and OOM-killed it (hot pages, unswappable). Obstructing
#     M8/M9 across the macro footprint drops DRT's working set well under RAM
#     while the strips keep M8/M9 for congestion relief. Macro placed at
#     (222.48, 2.16), size 1497.312 x 1535.76 -> top-right (1719.792, 1537.92).
set _blk [[[ord::get_db] getChip] getBlock]
set _u [$_blk getDbUnitsPerMicron]
foreach _ly {M8 M9} {
  set _L [[ord::get_db] getTech]
  set _layer [[[ord::get_db] getTech] findLayer $_ly]
  odb::dbObstruction_create $_blk $_layer \
    [expr int(222.480 * $_u)] [expr int(2.160 * $_u)] \
    [expr int(1719.792 * $_u)] [expr int(1537.920 * $_u)]
  puts "PRE-GR: obstructed $_ly over grid-macro interior (mem fix)"
}
