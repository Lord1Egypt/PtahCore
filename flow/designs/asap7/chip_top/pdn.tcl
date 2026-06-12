# chip_top PDN — design-local (CHIP_SPEC §3).
#
# Why not the platform default: its macro grids only know the fakeram
# contract (connect M4→M5), so the mac_grid macro — power pins = its
# own M6 straps, everything below M7 obstructed — generated an empty
# grid (PDN-0232/0233). The working pattern is the same one mac_grid
# itself uses one level down on the tiles: top-grid straps on the first
# layer the macro leaves clear (here M7, exact-OBS abstract — see
# flow/exact_obs_lef.py), and a macro grid whose connect rule vias them
# down onto the macro's pin straps (M7 is vertical, the M6 pin straps
# are horizontal full-width: a via candidate at every clear crossing).
source $::env(SCRIPTS_DIR)/util.tcl

####################################
# global connections
####################################
# The spine buffers are dont_touch (constraint.sdc) so the resizer and
# CTS keep their hands off the deliberate chains — but global_connect
# honors dont_touch by SKIPPING the instance (ODB-0383), leaving the
# buffers unpowered. Lift it for the connect, restore right after.
set spine_bufs [get_cells -hierarchical -filter "ref_name == BUFx24_ASAP7_75t_R"]
if { [llength $spine_bufs] > 0 } { unset_dont_touch $spine_bufs }

add_global_connection -net {VDD} -inst_pattern {.*} -pin_pattern {^VDD$} -power
add_global_connection -net {VSS} -inst_pattern {.*} -pin_pattern {^VSS$} -ground
global_connect

if { [llength $spine_bufs] > 0 } { set_dont_touch $spine_bufs }

####################################
# voltage domains
####################################
set_voltage_domain -name {CORE} -power {VDD} -ground {VSS}

####################################
# standard cell grid (west + north strips) — platform default geometry
# plus M7 straps that run the full core, crossing the grid macro where
# its exact M7 OBS leaves room
####################################
define_pdn_grid -name {top} -voltage_domains {CORE} -pins {M6}
add_pdn_stripe -grid {top} -layer {M1} -width {0.018} -pitch {0.54} -offset {0} -followpins
add_pdn_stripe -grid {top} -layer {M2} -width {0.018} -pitch {0.54} -offset {0} -followpins
add_pdn_stripe -grid {top} -layer {M5} -width {0.12} -spacing {0.072} -pitch {5.4} -offset {0.300}
add_pdn_stripe -grid {top} -layer {M6} -width {0.288} -spacing {0.096} -pitch {5.4} -offset {0.513}
# M7 pitch is deliberately coarse: at 4.32 µm (~346 straps) pdngen's
# via-candidate enumeration against the exact macro OBS blew past 6 GB
# and had to be killed; 17.28 µm (~87 straps × 0.544 wide) is ample
# copper and builds in minutes
add_pdn_stripe -grid {top} -layer {M7} -width {0.544} -spacing {0.096} -pitch {17.28} -offset {0.768}
add_pdn_connect -grid {top} -layers {M1 M2}
add_pdn_connect -grid {top} -layers {M2 M5}
add_pdn_connect -grid {top} -layers {M5 M6}
add_pdn_connect -grid {top} -layers {M6 M7}

####################################
# macro grids
####################################
# the 32×32 array: vias from the top M7 straps onto its M6 pin straps
define_pdn_grid -name {GridArray} -voltage_domains {CORE} -macro \
  -cells {mac_grid} -halo {2.0 2.0 2.0 2.0}
add_pdn_connect -grid {GridArray} -layers {M6 M7}

# fakerams (M4 pins under the top M5 straps) — platform default
define_pdn_grid -name {CORE_macro_grid_1} -voltage_domains {CORE} -macro \
  -orient {R0 R180 MX MY} -halo {2.0 2.0 2.0 2.0} -default
add_pdn_connect -grid {CORE_macro_grid_1} -layers {M4 M5}
define_pdn_grid -name {CORE_macro_grid_2} -voltage_domains {CORE} -macro \
  -orient {R90 R270 MXR90 MYR90} -halo {2.0 2.0 2.0 2.0} -default
add_pdn_connect -grid {CORE_macro_grid_2} -layers {M4 M5}
