# PtahCore — 32×32 abutted-array constraints (ASAP7, PICOSECONDS).
# docs/ARRAY_SPEC.md is the contract; read it before touching numbers.
#
# 2D traveling clock: row i's clock enters its west port i·δs after row
# 0's (the southward spine stagger chip_top must realize — modeled here
# as per-port source latency, the same way the 7b-3 row modeled B's
# traveling arrival). Within a row the clock then travels east through
# the tiles' characterised clk_in→clk_out arcs exactly as in 7b-3.
#
# δs is matched to the tiles' SOUTHBOUND feedthrough arcs (b_in→b_out,
# drain_n_in→drain_s_out — NOT rev-B floored, lib corners 152–216 /
# 173–192 ps) so the B and drain waves travel WITH the vertical clock
# stagger: hold needs the southbound data arcs ≥ δs (ARRAY_SPEC §1), so
# δs sits at the fast corner of those arcs. Verify in the finish report:
# capture-clock arrival at tile (i,j) must grow ~δs per row and ~δe per
# column, non-inverted, before trusting any number.

set clk_period 4000
set M 32
set N 32
set src 150
set ds 85       ;# southward stagger = the rev-C vertical feedthrough floor
                 # (measured in-context: b 88.9, drain floored 52.6→85;
                 # δs=150 was the first attempt — far-row drain led its
                 # capture clock by ~2.7 ns, CTS hold repair hit the
                 # buffer cap, RSZ-0060)
set de 82.34    ;# eastward clk arc, measured in-context (7b-3)

for {set i 0} {$i < $M} {incr i} {
    create_clock -name clk_$i -period $clk_period [get_ports "clk_v\[$i\]"]
    set_clock_latency -source [expr $src + $i * $ds] [get_clocks clk_$i]
    set_clock_uncertainty 100 [get_clocks clk_$i]
}

# South strip clock: end of the spine — one stagger past row 31, so the
# southbound drain wave (launched in row phase, traveling ~δs/tile)
# arrives in the capture clock's own phase (ARRAY_SPEC §1).
create_clock -name clk_s -period $clk_period [get_ports clk_s]
set_clock_latency -source [expr $src + $M * $ds] [get_clocks clk_s]
set_clock_uncertainty 100 [get_clocks clk_s]

# I/O budget: 15% of the period each side. Every per-row west input is
# delivered by chip_top in that row's phase (launch flops at the west
# spine) — input delay relative to that row's own clock.
set io_delay [expr 0.15 * $clk_period]
for {set i 0} {$i < $M} {incr i} {
    set pins [list "en_v\[$i\]" "zero_v\[$i\]" "row_hit_v\[$i\]"]
    foreach b {0 1} {
        lappend pins "slot_v\[[expr $i * 2 + $b]\]"
        lappend pins "dslot_v\[[expr $i * 2 + $b]\]"
    }
    for {set b 0} {$b < 32} {incr b} {
        lappend pins "a_v\[[expr $i * 32 + $b]\]"
    }
    set_input_delay -clock clk_$i $io_delay [get_ports $pins]
}

# B enters row 0's north edge traveling WEST→EAST with row 0's clock
# (the 7b-3 SDC contract, now owned by this design's north channel):
# column j's operand arrives j·δe after column 0's.
for {set j 0} {$j < $N} {incr j} {
    set d [expr $io_delay + $j * $de]
    set pins {}
    for {set b [expr $j * 32]} {$b < [expr ($j + 1) * 32]} {incr b} {
        lappend pins "b_n_flat\[$b\]"
    }
    set_input_delay -clock clk_0 $d [get_ports $pins]
}

# South strip interface: col-select walks the settled bus every cycle;
# drain_data is the registered output.
set_input_delay  -clock clk_s $io_delay [get_ports {drain_col_sel}]
set_output_delay -clock clk_s $io_delay [get_ports {drain_data}]

# ── Settled-bus drain (ARRAY_SPEC §3) ───────────────────────────────
# Every path INTO the drain register that crosses the tile sea goes
# through the bottom row's drain_s_out pins: the acc launches (the
# tiles' clk_in→drain_s_out arcs), row_hit, and drain_slot. All of them
# change at most once per 32 reads, and STORE's row-change settle
# bubble (store.sv) guarantees a full extra cycle before the first
# capture of a row — a genuine 2-cycle path, RTL-enforced, the same
# nature as 7b-3's drain_slot multicycle. The per-cycle drain_col_sel
# path does NOT cross the tiles and stays single-cycle.
set chain_pins {}
for {set j 0} {$j < $N} {incr j} {
    lappend chain_pins "row\\\[31\\\].col\\\[$j\\\].u_tile/drain_s_out\[*\]"
}
set_multicycle_path 2 -setup -through [get_pins $chain_pins]
set_multicycle_path 1 -hold  -through [get_pins $chain_pins]

# Reset is a slow, globally-distributed signal — exclude from timing.
set_false_path -from [get_ports "rst_v\[*\]"]

# Row 0's drain_n_in is tied LOW at the parent (a real constant, not a
# toggling signal -- see mac_grid.sv port comment). Excluding it mirrors
# the RTL tie; it is not a waiver of a live path.
set_false_path -from [get_ports "drain_n_flat\[*\]"]
