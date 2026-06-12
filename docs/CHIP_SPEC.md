# CHIP_SPEC — chip_top physical contract (Phase 7d)

The chip is where every contract the lower levels deferred gets
implemented **physically**. ARRAY_SPEC §2 deferred the southward clock
spine and the pre-delayed west/north delivery to chip_top; this spec
says how, and what the honesty checks are. The governing principle,
learned at every level since 7b-3: **delay structures built from logic
are fictions; delay structures built from clocking are physics.**

## 1. The spine — one clock, 34 taps

A single chip clock enters at the die edge. A deliberate buffer chain
(the **west spine**) runs south along the array's west edge with a tap
per row: tap *i* drives the grid's `clk_v[i]` pin, arriving ≈ *i*·δs
(δs = 85 ps, ARRAY_SPEC §1) after tap 0. The spine continues past row
31 to the **clk_s tap** (early-tap contract value ≈ 1.94 ns from
`gen_constraints.py`, NOT the spine end) for the grid's south-strip
drain register and the chip-side drain capture.

The chip-side logic (cmdproc, engines, SMEM) clocks from the spine
ROOT region (tap 0 phase). CTS may build a normal tree for that logic;
the spine itself is `dont_touch` — CTS never balances it, exactly as
the grid's rows were never CTS'd.

**Honesty check (standing):** post-route STA must report the arrival
at every `clk_v[i]` pin; the table must grow monotonically ≈ 85 ps/row
(the 7c clock-table check, now at chip scale).

## 2. Interface launch registers — contracts as clock taps

The grid's .lib pins carry setup/hold arcs vs their related `clk_v[i]`
derived from the characterised internal wave paths (the 31-hop
feedthrough chains). The hold side of those arcs is the per-bit
pre-delay contract (660–2,318 ps): data must NOT arrive at a west/north
pin earlier than its contract after its row clock.

Logic depth cannot guarantee a minimum delay (the 7c-3 lesson: min-
delay floors on port-port paths are NO-OPs and fast corners collapse
logic delay). Therefore every grid input is driven by a **launch
register clocked from a deliberately late spine tap**:

- **West bank, per row i** (en, zero, slot, dslot, row_hit, a[32]):
  registers placed beside row i's west edge, clocked by tap
  *i*·δs + D_w, where D_w is a dedicated delay stub off the row tap
  sized to the west contract class (≈ max west pre-delay …
  `gen_constraints.py` values; verified by STA, not assumed).
- **North bank, per column j** (b[32]): registers along the north
  edge, clocked by a **north spine** that travels east tapped per
  column (*j*·δe, δe = 82.34 ps) — the traveling-B contract becomes a
  traveling launch clock — plus the B pre-delay stub D_b.
- **Drain request** (row_hit, dslot, drain_col_sel) launches per-row /
  south with the same mechanism; drain_data returns into a chip-side
  capture register on the clk_s tap. Each launch stage adds one cycle
  of uniform latency — RTL models it explicitly (sim is bit-exact with
  the stage in), STORE's settle-bubble already tolerates it.

Setup is checked honestly by the lib arcs at chip STA (the late launch
eats into the 4 ns budget; the grid closed at +1156 ps under delivery
later than any tap+route can be). Hold is met by construction and
**verified** by the lib arcs — never waived.

## 3. Floorplan — the L strip

The grid macro (1497.312 × 1535.76 µm) sits at the die's south-east.
Std cells and SRAMs live in an L-shaped strip:

- **West strip**: cmdproc, barrier, load, store, mma_unit fetch FSM +
  operand registers (a_lat/b_lat, 16 Kib of flops), the 16
  `fakeram7_256x256` SMEM macros (2 copies × 8 banks, smem_phys.sv),
  the west spine + per-row launch banks.
- **North strip**: the north spine + per-column B launch banks (the
  fp8 B decoders feed them from the west corner).

Grid orientation stays R0 (rotating a routed macro flips routing
directions — not worth it). B's decoded fp32 bus (1024 b) routes from
the north-west corner along the north strip; the strip's height and
the west strip's width are floorplan parameters to iterate.

## 4. SMEM physical (7d-1, DONE)

64 KiB = 2 copies (read port A / B) × 8 banks of `fakeram7_256x256`
(1RW). LOAD's 16-B beats coalesce to 32-B line writes; a line write
displacing a read stalls the MMA fetch for one cycle (`rd_stall`
retry, verified bit-exact under 40% random stalls). Contracts
asserted: LOAD dest 32-B aligned, length multiple of 32, reads 32-B
aligned.

## 5. Abstracts & the false-clean discipline

- The grid abstract is generated in the same run as its GDS (a later
  `make generate_abstract` re-runs the whole flow — make's stage cache
  does not survive target re-invocation; the harden scripts chain it).
- Before ANY chip timing is trusted: dump the grid lib's arcs for
  `clk_v[*]`, `a_v[*]`, `b_n_flat[*]`, `en_v[*]` and confirm (a) data
  pins carry BOTH setup and hold arcs vs their related row clock, (b)
  hold magnitudes match the gen_constraints contract table, (c) no
  edge-typed arc terminates clock propagation (the 7b-3 falling_edge
  trap — patch class ready in flow/patch_tile_clk_arc.py).
- Per-tap clock arrivals and per-pin data arrivals get the same
  post-route honesty tables as 7b-3/7c.

## 6. Out of scope for 7d (recorded)

- GMEM is a behavioral TB contract (combinational read / posted write)
  — a real DDR/HBM controller is beyond an open-PDK teaching chip.
  The chip's gmem ports become top-level pins.
- Host instruction push stays a parallel port (no SerDes).
- Power: the platform PDN; no clock gating beyond fakeram ce.
