# PtahCore — 32×32 Array Spec (Phase 7c)

How 32 abutted traveling-clock rows stack into the full array without a
chip-wide clock tree. Companion to [TILE_SPEC.md](TILE_SPEC.md) (the tile
boundary contract) — this document is the **2D wave contract**: what the
grid guarantees, what it demands from `chip_top` (7d), and why every
constraint is RTL- or ISA-enforced rather than waived.

## 1. The 2D traveling clock

The row (7b-3) proved the eastward wave: clock and data enter the west
edge together and march tile-to-tile (+82.34 ps/tile measured), so a cell
only ever races its neighbour, never a global tree.

Stacking rows adds a southward axis. B operands enter the **north** edge
of row 0 and feed through each tile's `b_in→b_out` chain (~152–216 ps
lib-corner arc) to the row below; the drain marches the same direction.
If every row's clock arrived at the same time, row 31's B would lag its
clock by ~31 arcs ≈ 3 ns — an unclosable setup wall (the vertical version
of the rev-A hold wall, mirrored).

So the row clocks are **deliberately staggered south**: row *i*'s clock
enters its west edge `i × δs` after row 0's, where **δs ≈ the in-context
`b_in→b_out` arc**. Tile (i, j)'s clock is then
`t0 + i·δs + j·δe` (δe = 82.34 ps measured eastward arc) — a clock
*plane* tilted in both axes, matching the data wave in both axes:

- **B (southward):** arrives at row i after `i·δb`; clock arrives `i·δs`.
  δs is chosen ≈ δb, so the lag is bounded per row, not cumulative.
- **A / control (eastward):** unchanged from the row — enters each row's
  west edge in that row's clock phase, travels with it.
- **Drain (southward):** launched at row i (clock `i·δs`), passes
  `(31−i)` tiles' `drain_n_in→drain_s_out` arcs (δd), captured at the
  south strip whose flops are clocked at the **end of the spine**
  (`32·δs`). The southward clock gap `(32−i)·δs` cancels the chain
  `(31−i)·δd` when δd ≈ δs — the eastward trick, rotated 90°.

**Hold rule (vertical wave matching — learned per-bit in grid
attempts 1–2, HARDENING.md):** every feedthrough BIT marches at its own
consistent per-hop rate, and the fast corners span ~31–95 ps/hop — no
single stagger can wave-match a bus with a 3× internal spread over 31
hops, and `set_min_delay` floors inside the tile are a measured no-op
(port-to-port paths have no clocked endpoint; no repair stage services
them — the rev-B/C libs are byte-identical). The contract is therefore
**per-bit pre-delay at the grid boundary** (generated from the
characterised lib by `flow/designs/asap7/mac_grid/gen_constraints.py`):

- west input bit s: `io(s) = base + (δe − δ_min(s))·(N−1) + guard` —
  the same uniform pre-delay the row's hold repair built physically
  (~1.9 ns of buffers before tile 0), made explicit and per-bit;
- north B bit b: `io(b) = base + (δs − δb_min(b))·(M−1) + guard`,
  plus `j·δe` per column;
- drain capture `clk_s`: an **early spine tap** (≈1.94 ns, not the
  2.87 ns spine end) — at or before the earliest per-bit chain
  arrival, so every row is hold-positive by construction and the
  settled-bus multicycle absorbs all lateness on the setup side.

Validated on the placed 1024-macro DB with propagated clocks:
setup +1139 ps / hold +78 ps, TNS 0 both.

## 2. Who builds the spine

The grid is hardened with **per-row clock ports** (`clk_v[i]`, west
edge), each constrained `create_clock` + `set_clock_latency -source
(base + i·δs)`. The physical delay spine that realizes those arrivals is
**chip_top's job (7d)** — exactly the pattern 7b-3 used for B delivery
(the row modeled B's traveling arrival in SDC; the array now owns
delivering it). The grid's .lib/integration contract therefore states:

> chip_top must present row i's clock, A, and control at the grid's west
> edge at `i·δs` relative to row 0, and column j's B at the north edge at
> `j·δe` relative to column 0 (the north B channel travels west→east
> with the row-0 clock).

**Honesty check (standing):** the finish report must show capture-clock
arrival at tile (i, j) growing ~δs per row and ~δe per column,
non-inverted, before any signoff number is trusted.

## 3. Drain readout: settled-bus contract

Within a STORE burst the drained slot is static (latched at START) and
the selected row changes every N=32 elements (row-major drain). Between
row changes the entire 32-column chain output is a **settled static
bus** — the accumulators it reads are barrier-protected from concurrent
MMA writes (ISA rule: STORE of a slot may not overlap MMA into that
slot), and the per-cycle action is only the south strip's column mux
walking across it.

The honest constraints this earns (each mirrors RTL/ISA-enforced
behaviour, the same nature as the row's `drain_slot` multicycle):

| Path | Constraint | Enforced by |
|------|-----------|-------------|
| acc flops / `row_hit` / `drain_slot` → chain → south register | `set_multicycle_path 2 -setup` (hold 1) | STORE's **row-change settle bubble** (store.sv inserts 1 dead request cycle when the drain row index changes — including the first row of a burst; +32 cycles per 1024-element burst, ~3%) |
| `drain_col_sel` → column mux → south register | single-cycle | per-cycle col walk over the settled bus |

The drain remains REGISTERED (one register for the whole array, in the
south strip — the row-internal register of 7b-3 moves out of the row and
down to the grid boundary; external latency is unchanged: `drain_data`
answers the previous cycle's `drain_idx`).

## 4. Grid module & ports (`rtl/mac_grid.sv`)

Pure tile sea + south strip. Hardened as `mac_grid` with
`BLOCKS = mac_tile` (1024 macros, flat — a second hierarchy level would
mean a second .lib characterisation layer and a second falling-edge clk
arc trap; flat avoids both).

| Edge | Ports | Notes |
|------|-------|-------|
| west (per row i) | `clk_v[i]`, `rst_v[i]`, `en_v[i]`, `zero_v[i]`, `slot_v`, `dslot_v`, `row_hit_v[i]`, `a_v[i]` | pins placed at each row's macro-pin y; chip_top delivers in row-i phase |
| north | `b_n_flat[N*32]` | row 0's b_in pins; traveling input delay `j·δe` in SDC |
| south strip | `clk_s`, `drain_col_sel`, `drain_data[32]` (registered out) | strip flops clocked at end-of-spine phase (`32·δs`) |

`row_hit_v` is decoded OUTSIDE the grid (by `mac_array` in sim, by the
west engine strip at chip scale) — the grid stays pure.

In simulation all per-row ports are driven with the same signals and all
feedthroughs are zero-delay, so the grid is bit-identical to the flat
mac_array grid — every cell behaves exactly as verified since Phase 3.

## 5. Build order (7c)

1. `mac_grid.sv` RTL + `mac_array.sv` re-plumbed on top of it; STORE row
   bubble; pymodel/store.py twin; all suites bit-exact.
2. ORFS design `mac_grid` (flow/designs/asap7/mac_grid/): 1024-macro
   placement script (generated, both axes at 46.656 × 47.52 pitch), PDN,
   SDC per §1–§3; clk-arc lib patch automated in the BLOCKS flow.
3. Harden → fifth GDS. Signoff: honest setup/hold (INVARIANTS B4), DRC
   clean across all 1,984 abutted boundaries, `check_abutment.py`
   extended to 2D. Per-tile clock-arrival table in the report.
