# PtahCore — mac_cell timing constraints (ASAP7).
#
# ASAP7 in ORFS uses PICOSECONDS for SDC time values (the platform's
# example designs use e.g. `set clk_period 310`). 250 MHz = 4 ns = 4000 ps.
#
# Per docs/INVARIANTS.md §B4: a real, met target — no masked hold, no
# negative slack margin. Honest, not aspirational.

set clk_period 4000
create_clock -name clk -period $clk_period [get_ports clk]

# Source-synchronous intent: the array drives a "traveling" clock across
# abutted cells, so the parent presents the clock at the cell boundary with
# bounded skew — modest network latency + uncertainty, not an ideal tree.
set_clock_latency      -source 150 [get_clocks clk]
set_clock_uncertainty  100 [get_clocks clk]

# I/O budget: in the real array a cell's inputs are the registered outputs
# of abutted neighbour cells in the same clock domain, and drain_out feeds a
# nearby flop. 15% of the period each side (data ports listed explicitly —
# OpenROAD's SDC reader has no remove_from_collection, and clk must be
# excluded from input delay).
set io_delay [expr 0.15 * $clk_period]
set_input_delay  -clock clk $io_delay [get_ports {en zero slot a_f32 b_f32 drain_slot}]
set_output_delay -clock clk $io_delay [get_ports {drain_out}]

# Reset is a slow, globally-distributed signal — exclude from timing.
set_false_path -from [get_ports rst]
