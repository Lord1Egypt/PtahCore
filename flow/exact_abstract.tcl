# Regenerate the mac_grid abstract LEF with EXACT obstructions
# (write_abstract_lef -bloat_factor 0). ORFS generate_abstract hardcodes
# -bloat_occupied_layers, which blankets M6/M7 and buries the macro's
# own M6 power pins (PDN-0006 — docs/HARDENING.md). Run from the orfs
# image after `make generate_abstract`, then collapse the sub-M6 layers
# back to blankets with flow/exact_obs_lef.py.
read_lef /OpenROAD-flow-scripts/flow/platforms/asap7/lef/asap7_tech_1x_201209.lef
read_lef /OpenROAD-flow-scripts/flow/platforms/asap7/lef/asap7sc7p5t_28_R_1x_220121a.lef
read_lef /work/flow/results/asap7/mac_grid_mac_tile/base/mac_tile.lef
read_db /work/flow/results/asap7/mac_grid/base/6_final.odb
write_abstract_lef -bloat_factor 0 /work/flow/results/asap7/mac_grid/base/mac_grid_exact.lef
