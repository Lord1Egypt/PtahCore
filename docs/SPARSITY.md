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
| RTL select primitive | ✅ `rtl/sparse_select.sv` (Phase 9b) — the per-cell 2-of-4 mux, verified vs golden |
| RTL array integration | ⬜ **the redesign below** — invalidates the abutted GDS, needs Docker to re-harden |

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

Because step 2 rewrites the hardened, abutted, traveling-clock array (the
project's headline GDS) and invalidates its abstracts, it is scoped as a
deliberate, reviewed pass and run on the Docker/OpenROAD machine — the same
place the Phase 8/9 GDS land. The Docker-free correctness + throughput proof
(golden + pymodel) and the verified select primitive are complete and in
tree, so the redesign starts from a proven datapath block and a bit-exact
reference, with `sparse=0` held bit-identical throughout (the `mx=0`
discipline from Phase 8).
