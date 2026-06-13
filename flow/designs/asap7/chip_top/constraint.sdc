# PtahCore chip_top — ASAP7. Units: PICOSECONDS.
#
# Two clock ports, one external source: `clk` is the logic domain (CTS
# builds its tree); `clk_spine` feeds the dont_touch spine chains whose
# taps clock the launch banks and the grid macro's clk_v pins
# (CHIP_SPEC §1). STA propagates both through real instances — the
# inter-domain paths (root logic → stage A → stage B → grid pins) are
# timed honestly against the grid lib's characterised wave arcs.

set clk_period 4000

create_clock -name clk       -period $clk_period [get_ports clk]
create_clock -name clk_spine -period $clk_period [get_ports clk_spine]
set_clock_uncertainty 100 [get_clocks clk]
set_clock_uncertainty 100 [get_clocks clk_spine]

# The spine BACKBONE is deliberate physical structure: CTS must not
# balance it, the resizer must not size or buffer it (CHIP_SPEC §1).
# Match by INSTANCE PATH (*u_spine_*), NOT by ref_name == BUFx24 — the
# broad ref_name filter also froze u_clk_s_drv (the stage-A launch
# buffer) and any CTS distribution buffers, leaving the 806-fanout
# clk_s net un-treeable (ODB-0373, docs/HARDENING.md). Only the
# u_spine_w / u_spine_n chains are sacred; clk_s gets a normal tree.
set_dont_touch [get_cells -hierarchical -filter "name =~ *u_spine_*"]
set_dont_touch [get_nets  -hierarchical -filter "name =~ *u_spine_*"]

# Host/GMEM interface: behavioral-controller contract (CHIP_SPEC §6),
# generous sub-cycle budgets at the pins. Data ports listed explicitly
# — OpenROAD's SDC reader lacks remove_from_collection (mac_cell-era
# failure log).
set_input_delay  -clock clk 800 [get_ports {rst push_en push_instr[*] gmem_rd_data[*]}]
set_output_delay -clock clk 800 [get_ports {fifo_full idle gmem_rd_addr[*] gmem_wr_en gmem_wr_addr[*] gmem_wr_data[*] gmem_wr_nbytes[*]}]

# Propagate from the start (the mac_grid lesson: ideal-clock analysis
# invents phantom violations the repair stages then chase).
set_propagated_clock [all_clocks]
