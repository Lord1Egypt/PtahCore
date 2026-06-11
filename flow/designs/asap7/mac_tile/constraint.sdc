# PtahCore — mac_tile timing constraints (ASAP7, time unit = PICOSECONDS).
#
# Same 250 MHz contract as the mac_cell tile. The clock enters on clk_in
# (west) and leaves on clk_out (east) as a feedthrough — inside the tile
# CTS hangs the two pipeline-register banks off it; the clk_in→clk_out
# arc is characterised into the .lib and the row's traveling-clock STA
# (7b-3) sums the real arcs. clk_out is a clock pin, not data: no output
# delay on it.

set clk_period 4000
create_clock -name clk -period $clk_period [get_ports clk_in]

# Source-synchronous intent (TILE_SPEC §3): the west neighbour presents
# the clock at the boundary with bounded skew — modest latency, not an
# ideal tree.
set_clock_latency      -source 150 [get_clocks clk]
set_clock_uncertainty  100 [get_clocks clk]

# I/O budget: 15% of the period each side. In the abutted row a tile's
# west/north inputs are its neighbours' east/south outputs in the same
# traveling-clock domain. Data ports listed explicitly (no
# remove_from_collection in OpenROAD's SDC reader; clk_in/clk_out and
# rst_in/rst_out must stay out of the data sets).
set io_delay [expr 0.15 * $clk_period]
set_input_delay  -clock clk $io_delay [get_ports {en_in zero_in slot_in drain_slot_in row_hit_in a_in b_in drain_n_in}]
set_output_delay -clock clk $io_delay [get_ports {en_out zero_out slot_out drain_slot_out row_hit_out a_out b_out drain_s_out}]

# Reset is a slow, globally-distributed signal — exclude from timing
# (rst_out is its feedthrough continuation).
set_false_path -from [get_ports rst_in]
