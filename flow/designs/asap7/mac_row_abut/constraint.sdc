# PtahCore — abutted traveling-clock row constraints (ASAP7, PICOSECONDS).
#
# The clock is defined ONCE at the row's west port. It reaches tile 0's
# clk_in directly and every later tile through the chain of characterised
# clk_in→clk_out macro arcs (~89 ps/tile) — there is no row CTS and no
# balanced tree. STA therefore sees each tile's capture clock arriving
# progressively later, exactly in step with the west→east data wave
# traveling through the matching a/ctrl feedthrough arcs (~84–98 ps/tile).
# That cancellation IS the traveling clock; nothing is waived.
#
# HONESTY CHECK: in the finish report the capture-clock arrival at tile j
# must grow ~90 ps per tile and stay NON-INVERTED (write_timing_model
# encodes the clk feedthrough arc as falling_edge with a negative rise
# reference — if STA misreads it, paths to far tiles will show half-period
# checks or inverted edges; verify before trusting any number).

set clk_period 4000
create_clock -name clk -period $clk_period [get_ports clk]

set_clock_latency      -source 150 [get_clocks clk]
set_clock_uncertainty  100 [get_clocks clk]

# Virtual I/O clock: the row's launch/capture flops sit at the WEST edge,
# where the clock enters — same source latency as clk, no tree on top.
create_clock -name vclk -period $clk_period
set_clock_latency -source 150 [get_clocks vclk]
set_clock_uncertainty  100 [get_clocks vclk]

# I/O budget: 15% of the period each side. The drain readout is launched
# by each tile's TRAVELING clock and returns west — single-cycle it
# failed honestly (−460 ps post-route on all 32 drain_out bits), so the
# row REGISTERS the drain at its boundary (mac_row.sv) and STORE grew a
# write-back stage. Nothing is waived; the cycle is bought in RTL.
set io_delay [expr 0.15 * $clk_period]
set_input_delay  -clock vclk $io_delay [get_ports {en zero slot a_f32 drain_slot drain_idx}]
set_output_delay -clock vclk $io_delay [get_ports {drain_out}]

# B enters per column from the north. The ARRAY delivers column j's B
# operand traveling WITH the clock (the 7c contract: the B bus runs
# west→east along the array's north edge, accumulating the same per-tile
# delay as the clock chain). A flat input delay would make far columns'
# B arrive ~2.5 ns before their capture clocks — a phantom hold wall the
# real array never produces. clk feedthrough measured 82.34 ps/tile.
set clk_ft 82.34
for {set j 0} {$j < 32} {incr j} {
    set d [expr $io_delay + $j * $clk_ft]
    set bits {}
    for {set k [expr $j * 32]} {$k < [expr ($j + 1) * 32]} {incr k} {
        lappend bits "b_f32_flat\[$k\]"
    }
    set_input_delay -clock vclk $d [get_ports $bits]
}

# drain_slot is BURST-STATIC by the STORE contract (store.sv latches it
# at START; the first drain capture is ≥2 cycles later and it holds for
# the whole 1024-element burst). Its ~2.9 ns feedthrough chain to the
# far tiles is therefore a genuine 2-cycle path — this constraint
# mirrors RTL-enforced behaviour (same nature as the rst false path),
# the opposite of masking a real same-cycle race.
set_multicycle_path 2 -setup -from [get_ports drain_slot]
set_multicycle_path 1 -hold  -from [get_ports drain_slot]

# Reset is a slow, globally-distributed signal — exclude from timing.
set_false_path -from [get_ports rst]
