# PtahCore — Tile Abutment Spec

The boundary contract every hardened tile must satisfy so cells abut
edge-to-edge into the 32×32 array **without a chip-wide clock tree**.
Written *before* scaling on purpose: retrofitting an abutment boundary
onto already-hardened macros is the single biggest avoidable cost in a
tiled accelerator flow (the prior-art project hit exactly this and never
fully recovered timing at chip scale).

## Why abutment

A 32×32 grid of `mac_cell` macros (1,024 of them) cannot be served by one
balanced clock tree at 7nm — CTS insertion delay and skew across a die
that large is unbridgeable by the resizer. Instead:

- Each cell is hardened as a **tile** with a fixed boundary.
- Tiles **abut** (share edges, no routing channel between them).
- The clock enters a tile on one edge and exits the opposite edge — a
  **source-synchronous "traveling" clock** marches across each row, so a
  cell only ever sees bounded local skew vs. its neighbours, never the
  global tree.

## The contract

A tile is abutment-ready iff:

1. **Fixed outline.** Width/height are identical across all instances and
   a multiple of the ASAP7 site grid **and of every routing-track pitch on
   layers the tile owns** — `place_macro` snaps macros to tracks, so a
   dimension that is site-aligned but not track-aligned flips the track
   phase tile-to-tile and zero-gap abutment becomes overlap (learned the
   hard way: the first 46.44 µm tile snapped +24 nm = half an M5 pitch,
   MPL-0041). On ASAP7 with the tile owning M1–M5 the quanta are
   lcm(0.054, 0.036, 0.048) = **0.432 µm in x** and
   lcm(0.27, 0.036, 0.048) = **2.16 µm in y**; the tile is
   46.656 × 47.52 µm. The array places tiles on this exact pitch with
   zero inter-tile gap.

2. **Edge-aligned power.** VDD/VSS rails exit both the left and right
   edges at the same y-coordinates on every tile, so power is continuous
   across an abutted row by construction (no PDN stitching).

3. **Clock pins on opposing edges.** `clk_in` on the west edge, `clk_out`
   on the east edge, same y. A row connects each cell's `clk_out` to its
   eastern neighbour's `clk_in`. Insertion delay per tile is characterised
   and bounded; the parent budgets it as latency, not CTS.
   **Wave matching (measured the hard way):** every same-direction data
   feedthrough must be at least as slow as the clock feedthrough
   (`set_min_delay` ≥ the clk arc, ~82 ps on ASAP7) — unmatched 1-bit
   controls crossed in ~46 ps and far tiles hold-violated the moment the
   clock became STA-visible. Setup tolerates data lagging the clock; hold
   does not tolerate it leading. Two .lib traps when consuming the tile:
   the clk arc must be re-encoded combinational or STA silently
   unconstrains every downstream tile (`flow/patch_tile_clk_arc.py`), and
   per-tile clock arrival must be verified in the report before trusting
   any hierarchical number.

4. **Signal pins only on the edges that carry them.**
   - A-operand broadcast enters the **west** edge, exits **east** (row
     broadcast).
   - B-operand broadcast enters the **north** edge, exits **south**
     (column broadcast).
   - `drain_out` exits the **south** edge into the STORE drain mux.
   - No signal pin sits on an edge it doesn't need — keeps abutted routing
     local.

5. **No over-the-tile routing from the parent.** The parent may only
   connect pins at abutted edges. Nothing routes *across* a tile. This is
   what keeps the parent from needing a global tree or long detours.

6. **Characterised `.lib` matches placed context.** The tile's timing
   model (`write_timing_model`) is extracted under the **same clock-entry
   assumptions** the parent uses. A `.lib`/parent mismatch here is the
   classic source of phantom STA skew — it must be checked, not assumed.

## Invariants (machine-checkable — see docs/INVARIANTS.md)

- Every `mac_cell` instance has byte-identical outline + pin geometry.
- Abutted rows have zero DRC at tile boundaries.
- Per-tile clock insertion delay ≤ the parent's per-tile latency budget.
- No parent wire crosses a tile outline (LEF obstruction check).

## Build order

1. `mac_cell` tile → clean GDS, timing closed, boundary per this spec.
2. 1×N abutted row with the traveling clock → timing closed.
3. Full 32×32 array via row abutment.
4. `chip_top`: array + the (non-tiled) control/memory/engine macros.

Status and per-step results live in `docs/SYNTHESIS.md` (pre-layout) and
will extend into `docs/HARDENING.md` as ASAP7 P&R produces real numbers.
