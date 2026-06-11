# PtahCore — mac_row timing constraints (ASAP7, time unit = PICOSECONDS).
#
# Same 250 MHz contract as the mac_cell tile. Row-level CTS balances the
# clock into the 32 macro clk pins (insertion delay comes from the
# mac_cell .lib); the traveling clock replaces this in Phase 7b.

set clk_period 4000
create_clock -name clk -period $clk_period [get_ports clk]

set_clock_latency      -source 150 [get_clocks clk]
set_clock_uncertainty  100 [get_clocks clk]

# Virtual I/O clock. The row's data/control inputs are launched by parent
# flops on the SAME clock tree, whose launch edge therefore sees network
# latency comparable to the row's own insertion. Timing I/O against the
# ideal clock instead manufactures ~1 ns of phantom hold violation into
# every macro data pin (first run: hold repair hit the buffer cap at 1540
# buffers, worst -517 ps — pure constraint artifact). vclk carries the
# modeled total launch latency, set to the MEASURED capture latency at
# the far macro clk pin (6_finish: 150 source + ~586 row tree ≈ 736,
# rounded to 750). First estimate was 1150; the honesty check below
# caught the 414 ps gap and it was tightened — hold is checked ~400 ps
# harder with the true value.
#
# The latency MUST be -source: ORFS runs `set_propagated_clock
# [all_clocks]` after CTS, and OpenSTA then discards plain (network)
# clock latency — vclk silently reverted to ideal and the phantom hold
# wall came back (second run: worst -669 ps, hold-buffer cap at 1564;
# slack math matched "latency ignored" exactly: 600 io − 150 src −
# ~990 tree − 29 lib hold − 100 unc ≈ −669). Source latency survives
# propagation.
#
# HONESTY CHECK (INVARIANTS-style): after route, the real insertion
# delay must match this estimate to within a few hundred ps — verify in
# the 6_finish report before trusting hold numbers.
create_clock -name vclk -period $clk_period
set_clock_latency -source 750 [get_clocks vclk]
set_clock_uncertainty  100 [get_clocks vclk]

# I/O budget: 15% of the period each side, as for the cell. The drain
# path (drain_idx → 32:1 mux over macro drain_out arcs → drain_out) is
# combinational across the full row — if that fails setup here, it fails
# honestly and gets registered/pipelined, not waived.
set io_delay [expr 0.15 * $clk_period]
set_input_delay  -clock vclk $io_delay [get_ports {en zero slot a_f32 b_f32_flat drain_slot drain_idx}]
set_output_delay -clock vclk $io_delay [get_ports {drain_out}]

# Reset is a slow, globally-distributed signal — exclude from timing.
set_false_path -from [get_ports rst]
