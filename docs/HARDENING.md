# PtahCore — Hardening Log (ASAP7 7nm)

Real place-and-route results, recorded honestly as each block closes.
**No masked hold violations, no negative slack margins** (see
docs/INVARIANTS.md §B4). If a block doesn't close, that's recorded too.

## Flow

OpenROAD-flow-scripts (ORFS) on the ASAP7 predictive PDK, driven by
`flow/harden.sh`:

```bash
# one-time: pull the flow image (WSL2 / Docker-Desktop needs a clean
# credential-helper-free config)
mkdir -p /tmp/dockercfg && echo '{}' > /tmp/dockercfg/config.json
DOCKER_CONFIG=/tmp/dockercfg docker pull openroad/orfs:latest

# harden a block
flow/harden.sh mac_cell
```

Design configs live in `flow/designs/asap7/<block>/`:
- `config.mk` — RTL list, platform, floorplan/utilisation
- `constraint.sdc` — clock + I/O timing (250 MHz target)

## Build order (per docs/TILE_SPEC.md)

1. **`mac_cell` tile** — the leaf abutted 1,024×. Must close timing, pass
   DRC, and present the abutment boundary contract.
2. **1×N row** — cells abutted with the traveling clock.
3. **32×32 array** — full grid via row abutment.
4. **`chip_top`** — array + control/memory/engine macros.

## Results

| Block | Status | Clock | Worst setup slack | Worst hold slack | Area | Util | Notes |
|-------|--------|-------|------------|------------|------|------|-------|
| `mac_cell` (pipelined mul \| add) | ✅ **GDS complete** | 250 MHz (4000 ps) | **+1928 ps** | **+13 ps** | **750 µm²** | 44% | signoff: 0 setup / 0 hold / 0 slew / 0 cap / 0 fanout violations, **DRC clean**; crit path ~2.07 ns → ~480 MHz capable |
| row (1×N) | ⬜ | — | — | — | — | — | next |
| array (32×32) | ⬜ | — | — | — | — | — | — |
| `chip_top` | ⬜ | — | — | — | — | — | — |

_(Pre-layout generic-gate area baselines are in docs/SYNTHESIS.md.)_

## First GDS — `mac_cell` on ASAP7

Full RTL→GDSII, signoff clean, on a laptop under WSL2:

![mac_cell routed layout](img/mac_cell_gds.webp)

*Routed `mac_cell` macro — 750 µm² @ 44% utilisation, ASAP7 7nm predictive
PDK. Clock tree below (17 buffers, 2-level H-tree, 164 sinks):*

![mac_cell clock tree](img/mac_cell_clock_tree.webp)

The GDS itself (`flow/results/asap7/mac_cell/base/6_final.gds`) is a build
artifact — regenerate with `flow/harden.sh mac_cell` (~6 min).

### ⚠️ The picosecond units bug — and what actually happened

The mac_cell **closes 250 MHz setup with ~2 ns margin.** Getting there took a
detour worth recording honestly:

1. **Phase 6a** first P&R reported "WNS −2237 ps, fails 250 MHz." **This was a
   units bug.** ASAP7 SDC time is in **picoseconds** (the platform's own
   examples use `set clk_period 310`). My `set clk_period 4.0` meant **4 ps =
   250 GHz**, so of course everything "violated" — and the negative "ps" values
   were literally the real path delays: ~2.24 ns combinational.
2. **Phase 6b** pipelined the MAC (split multiply | add) — genuinely good design
   that cut the critical path and kept all 89 tests bit-exact — but still read
   the clock as 4 ps, so it looked like it "still failed at −1309 ps." I even
   chased a phantom "the adder can't be pipelined" conclusion.
3. **Phase 6c** found the bug: `4.0` → `4000` ps. With the correct clock the
   pipelined mac_cell closes 250 MHz setup at **+1994 ps slack**, critical path
   ~2.0 ns (≈ 500 MHz capable), 675 µm².

**Lessons kept:** always check the platform's SDC time unit; the pipelined MAC
is still the design we ship (more margin, ~500 MHz headroom, bit-exact). The
accumulate add is a loop-carried dependency and *would* be the floor if it were
the long pole — it isn't here (the multiply is, at ~2 ns), but a Kulisch
fixed-point accumulator remains the right move if we ever push past ~500 MHz.

### Hold — closed with real positive margin

CTS-stage `repair_timing` inserts hold buffers. With the default
`HOLD_SLACK_MARGIN = 0` it repairs to *exactly* zero slack — and post-route
RC then pushed 2 paths to **−1.11 ps**. The honest fix is the **opposite**
of autogpu's masking (they set the margin *negative* to hide violations,
INVARIANTS §B4): we set `HOLD_SLACK_MARGIN = 15` so repair demands +15 ps
of real slack at CTS, absorbing post-route RC pessimism. Final signoff:
**0 hold violations, worst hold slack +13.01 ps.**

<details><summary>Historical Phase 6b notes (pre-correction — kept for the record)</summary>

Pipelined the MAC: split multiply ↔ add, and (briefly) pipelined `fp32_mul`
internally. Reverted the internal-mul split — registering the raw product
dragged the mul's normalize into the add stage and measured worse than
registering the full product. Final design: combinational `fp32_mul`, register
its full output, combinational accumulate add. The pre-correction analysis
below read the clock as 4 ps and is superseded by the section above.

</details>

ASAP7 is a *predictive, deliberately pessimistic* PDK; the ns figures are
relative-honest, not a foundry guarantee — but the closure discipline is the
same either way.

## Failure log

Every distinct flow error hit, with root cause + fix, so it's never
re-debugged from scratch.

| Error / symptom | Block | Root cause | Fix |
|-----------------|-------|-----------|-----|
| "fails 250 MHz, WNS −2237 ps" | mac_cell | **ASAP7 SDC time is in picoseconds** — `set clk_period 4.0` = 4 ps (250 GHz), so everything "violated" by its real path delay | use ps: `set clk_period 4000`; design closes with +1994 ps |
| `read_verilog`: "File `SYNTHESIS' not found" | mac_cell | ORFS default Yosys frontend needs `-D` prefix on defines | `VERILOG_DEFINES = -DSYNTHESIS` (not `SYNTHESIS`) |
| SDC: `invalid command name "remove_from_collection"` | mac_cell | OpenROAD's SDC reader lacks `remove_from_collection` | list data ports explicitly in `set_input_delay` |
| `cts.tcl: child killed: illegal instruction` (SIGILL) | mac_cell | **NOT TritonCTS** (initial diagnosis was wrong — CTS + hold repair had already completed in the log). The crash is `run_lec_test` exec-ing the image's `kepler-formal` LEC binary, which uses an instruction this host lacks (i7-9750H has AVX2 but no AVX-512) | `export LEC_CHECK = 0` in config.mk. LEC is an optional post-repair equivalence check; netlist-vs-RTL equivalence is covered by the bit-exact cocotb suite. CTS→route→GDS proceed normally. |
| 2 hold violations post-route, worst −1.11 ps | mac_cell | `HOLD_SLACK_MARGIN` defaults to 0 → CTS hold repair fixes to exactly zero slack, then detailed-route RC pushes marginal paths slightly negative | `export HOLD_SLACK_MARGIN = 15` (a **positive** margin — real extra slack, not masking). Signoff: 0 hold violations, worst +13.01 ps |
