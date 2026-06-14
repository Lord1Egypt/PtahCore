# 2:4 Structured Sparsity (Phase 9)

PtahCore supports NVIDIA-style **2:4 structured sparsity** on operand A:
in every group of 4 consecutive K-lanes, exactly 2 are nonzero. The result
is bit-identical to the dense matmul of the decompressed A; the win is
**~2× throughput** (only K/2 MAC steps run).

## Status

| Layer | State |
|-------|-------|
| Format + golden reference | ✅ `golden/sparse24.py` (Phase 9a) |
| pymodel (K/2 steps, per-row B gather) | ✅ `pymodel/` (Phase 9a) — bit-exact + 2× proven by step count |
| RTL select primitive | ✅ `rtl/sparse_select.sv` (Phase 9b-i) — the per-cell 2-of-4 mux, verified vs golden |
| RTL sparse compute datapath | ✅ `rtl/mac_array_sparse.sv` (Phase 9b-ii) — full K/2-step sparse array, per-cell select feeding the untouched mac_cell, bit-exact + 2× by cycle count |
| Abutted-array integration + GDS | ⬜ **9b-iii below** — fold the select into the traveling-clock tile; invalidates the GDS abstracts, needs Docker to re-harden |

## Format

A is stored **compressed**:

- `a_vals` — `M × (K/2)` fp8: the 2 kept values per group, in K order
- `a_meta` — `M × (K/4)` bytes: per group, two 2-bit kept-lane indices,
  `idx0 = meta[1:0]`, `idx1 = meta[3:2]`, ascending

`MMA … sparse=1, meta_smem=…` carries it. Both operands obey the SMEM read
contract (32-B `RD_BYTES` lines).

## Why the array integration is a redesign, not an add-on

The compute array is **broadcast**: each cycle, A column `k` drives every
column (per-row `a_bus`), B column `k` drives every row (per-column
`b_n_flat`). Cell `(i,j)` computes `A[i,k]·B[j,k]`, and **B is shared down
each column** (same value for all rows `i`).

2:4 metadata is **per-row**: row `i` keeps lanes that row `i+1` may not. So
to skip the zero lanes, cell `(i,j)` needs `B[j, actual_k(i)]` where
`actual_k` depends on row `i`'s metadata — i.e. **a different B per row in
the same column**. A shared column broadcast cannot deliver that.

The architecturally-correct fix (matching Sparse Tensor Cores): deliver the
**4-lane B group window** down each column and let each cell select 2 of 4
with its row's metadata — one `sparse_select` per cell. That means:

1. **`mac_cell`** gains a 4-lane B input + a 2-bit-per-step metadata input
   and an `sparse_select` mux (built + verified here). `sparse=0` ties the
   window's lane 0 to today's single `b_f32` → bit-identical dense path.
2. **`mac_tile` / `mac_row` / `mac_grid`** B feedthrough widens 1→4 lanes
   and routes per-row metadata — this **changes the TILE_SPEC abutment pin
   contract** and the traveling-clock B-wave, so all five existing GDS
   abstracts must be re-hardened.
3. **`mac_array` / `mma_unit`** sequence K/2 group-steps (vs K), present the
   group window, and fetch `a_vals` + `a_meta` instead of the dense tile.

### What is already proven in RTL (Docker-free)

`rtl/mac_array_sparse.sv` is the **full sparse compute datapath in real
RTL** — it does step 1 (the per-cell 2-of-4 select) and step 3 (K/2-step
sequencing, compressed-A operands) on a flat array, reusing the **untouched**
`mac_cell` leaf, and is verified bit-exact vs golden plus the 2× throughput
by cycle count (`test_mac_array_sparse`). It deliberately does NOT use the
abutted `mac_grid`, so none of the five hardened GDS modules change.

The only remaining piece (**9b-iii**) is step 2: folding that proven select
into the abutted, traveling-clock tile — widening `mac_tile`'s B feedthrough
1→4 lanes and routing `meta_sel` east with the A wave. That changes the
physical tile pins, so it invalidates the GDS abstracts and is bundled with
the chip re-harden on the Docker/OpenROAD machine. It starts from a proven
datapath block (`mac_array_sparse.sv`), the verified primitive
(`sparse_select.sv`), and a bit-exact reference (golden + pymodel), holding
`sparse=0` bit-identical throughout (the `mx=0` discipline from Phase 8).
