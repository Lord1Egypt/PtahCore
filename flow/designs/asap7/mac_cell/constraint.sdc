# PtahCore — mac_cell timing constraints (ASAP7).
#
# Target: 250 MHz (4 ns) — the honest, closable target from config.py /
# PLAN.md. Not an aspirational number we later mask with negative hold
# margin; the whole point of PtahCore vs. the prior art is that this
# closes for real.

set clk_period 4.0
create_clock -name clk -period $clk_period [get_ports clk]

# Source-synchronous intent: the array drives a "traveling" clock across
# abutted cells, so the parent presents the clock at the cell boundary
# with bounded skew. Model that as a modest network latency + uncertainty
# rather than assuming an ideal chip-wide tree.
set_clock_latency      -source 0.15 [get_clocks clk]
set_clock_uncertainty  0.10 [get_clocks clk]

# I/O budgets: operands (a_f32/b_f32) and control arrive registered from
# the row/column edge; drain_out feeds the STORE mux. Give 30% of the
# period each side so the cell is characterised as a tile, not in
# isolation. (Data ports listed explicitly — OpenROAD's SDC reader has no
# remove_from_collection, and clk must be excluded from input delay.)
set io_delay [expr 0.30 * $clk_period]
set_input_delay  -clock clk $io_delay [get_ports {en zero slot a_f32 b_f32 drain_slot}]
set_output_delay -clock clk $io_delay [get_ports {drain_out}]

# Reset is a slow, globally-distributed signal — exclude from timing.
set_false_path -from [get_ports rst]
