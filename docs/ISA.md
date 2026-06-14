# PtahCore — ISA Specification

Minimal Blackwell-style ISA for an FP8 matmul accelerator: three data ops
(LOAD, MMA, STORE), barrier ops (BAR.INIT, WAIT), and a hardware loop
(REPEAT). Six instructions total.

Three deliberate departures from the Hopper/Blackwell conventions:

1. **WAIT carries no phase operand** — hardware tracks expected phase.
2. **STORE is asynchronous** — completion via barrier, like LOAD/MMA.
3. **REPEAT** — hardware loop with per-iteration address strides.

## Memory spaces

| Space | Purpose | Addressing |
|-------|---------|-----------|
| GMEM | Off-chip DRAM: A, B, D tensors | byte, 64-bit pointers |
| SMEM | On-chip scratchpad: operand tiles + mbarrier objects | byte, 32-bit offsets |
| TMEM | Accumulators, distributed in MAC cells | slot index (0..TMEM_SLOTS-1) |

No general-purpose register file. Operands are immediates.

## Data types

- **Operands (A, B):** fp8 — **e4m3 or e5m2**, selected per-MMA by `fmt`.
- **Accumulator (D):** fp32.
- **Output:** fp32 or fp8-e4m3 — STORE selects via `dtype`.
- **Block scale (MXFP8, Phase 8):** optional **E8M0** per-block scale —
  8-bit, value `2^(X-127)`, `X∈[0,254]` (`X=255`=NaN). With K=32 = one OCP
  MX block, A carries one scale per row (M), B one per column (N). Enabled
  per-MMA by `mx`; applied as a fp32 **exponent add** at drain.

## Barrier objects (mbarrier)

16-byte objects in SMEM's reserved prefix (`NUM_BARRIERS` of them):

```
offset size field       description
0      2    pending     arrivals remaining before flip-eligible
2      2    expected    reload value for pending after flip
4      4    tx_pending  bytes remaining before flip-eligible
8      1    phase       0|1, flips on completion
9      7    reserved
```

**Flip rule** — when `pending == 0 && tx_pending == 0`, atomically:
`phase ^= 1; pending = expected;` any stalled WAIT on this barrier wakes.

## Instructions

### `BAR.INIT bar, count`
Initialize mbarrier `bar`: `expected = pending = count; tx = 0; phase = 0`.
Also resets the cmdproc's expected-phase tracker bit for `bar` to 0.
Synchronous; must precede any LOAD/MMA/STORE referencing `bar`.

### `LOAD bar, gmem, smem, bytes [, gstep, sstep]`
Async DMA gmem → smem. `bytes` multiple of 16.

- **Issue (atomic):** `bar.tx += bytes`
- **Completion:** `bar.tx -= bytes; bar.pending -= 1` → flip rule
- `gstep`/`sstep`: per-REPEAT-iteration strides (see REPEAT)

### `MMA bar, A_smem, B_smem, slot, accum, fmt [, astep, bstep] [, mx, sa_smem, sb_smem]`
Async fp8 matmul: `tmem[slot] ← (accum ? tmem[slot] : 0) + A @ B^T`.

- A is (M, K) fp8 row-major at `A_smem`; B is (N, K) fp8 row-major at `B_smem`
- `fmt`: 0 = e4m3, 1 = e5m2
- Takes K cycles (one K-step/cycle). **Completion:** `bar.pending -= 1`
- v1 shape is fixed at (MMA_M, MMA_N, MMA_K) from `config.py`; the
  instruction carries no M/N/K fields (multi-shape is a Phase 10 extension)
- **`mx` (MXFP8, Phase 8):** when 1, `sa_smem` points at the M E8M0 row
  scales and `sb_smem` at the N E8M0 col scales (`X=255`=NaN). The accumulator
  is unchanged; the scale `2^((ea[i]-127)+(eb[j]-127))` is applied to each
  output element at **drain** as a fp32 exponent add + saturate
  (overflow→±inf, underflow→±0). `mx=0` (default) is bit-identical to plain
  fp8 — single-block op (use the plain accum K-loop for reduction).
- **Scale operands** are read as one 32-B `RD_BYTES` line: `sa_smem`/`sb_smem`
  are 32-B aligned and their LOAD writes a full 32-B line.

### `STORE bar, gmem, slot, dtype [, gstep]`
**Async** drain of TMEM `slot` to gmem, row-major, one element/cycle.

- `dtype = 0`: fp32 out (4 B/elem) · `dtype = 1`: convert to fp8-e4m3 (1 B/elem)
- **Completion (all M·N elements written):** `bar.pending -= 1`
- Issuing an MMA that targets a slot mid-drain is a software error (asserted
  in simulation; undefined on silicon)

### `WAIT bar`
Block the front-end until `bar.phase != tracker[bar]`, then `tracker[bar] ^= 1`.

The per-barrier tracker bit lives in the cmdproc, initialized by BAR.INIT.
Software never tracks phases. Because the tracker toggles on each completed
WAIT, the same `WAIT bar` instruction is correct on every REPEAT iteration.

### `REPEAT count, len`
The next `len` instructions form a body executed `count` times total.

- Body instructions with stride fields compute their effective address as
  `base + i * step` on iteration `i` (i = 0 … count-1).
- Bodies may contain WAIT (auto-phase makes this safe). Nesting is illegal.
- Constraints: `1 ≤ len ≤ REPEAT_MAX_LEN`, `1 ≤ count ≤ 65535`.

## Canonical kernels

### Single tile
```
BAR.INIT b_ld, 2          # A + B loads
BAR.INIT b_mma, 1
BAR.INIT b_st, 1

LOAD  b_ld, A_g, A_s, A_bytes
LOAD  b_ld, B_g, B_s, B_bytes
WAIT  b_ld
MMA   b_mma, A_s, B_s, slot=0, accum=0, fmt=e4m3
WAIT  b_mma
STORE b_st, D_g, slot=0, dtype=0
WAIT  b_st
```

### K-loop over T tiles — 11 instructions for ANY T
```
BAR.INIT b_ld, 2
BAR.INIT b_mma, 1
BAR.INIT b_st, 1

# prime: tile 0 zeroes the accumulator
LOAD  b_ld, A_g, A_s, AB        ; LOAD b_ld, B_g, B_s, BB ; WAIT b_ld
MMA   b_mma, A_s, B_s, 0, accum=0 ; WAIT b_mma

REPEAT T-1, 5                   # tiles 1..T-1
  LOAD  b_ld, A_g+AB, A_s, AB, gstep=AB
  LOAD  b_ld, B_g+BB, B_s, BB, gstep=BB
  WAIT  b_ld
  MMA   b_mma, A_s, B_s, 0, accum=1
  WAIT  b_mma

STORE b_st, D_g, 0, dtype=0 ; WAIT b_st
```

### Epilogue overlap (async STORE)
```
MMA   b_mma, …, slot=0 ; WAIT b_mma
STORE b_st, D_g, slot=0          # fire and forget
LOAD  b_ld2, A2_g, A2_s, …       # next kernel's load runs DURING the drain
WAIT  b_ld2
WAIT  b_st                       # join the store only when actually needed
```

## Encoding (sketch — finalized at Phase 3 cmdproc RTL)

Fixed 64-bit instructions, 4-bit opcode.

| Opcode | Mnemonic |
|--------|----------|
| 0x0 | BAR.INIT |
| 0x1 | LOAD |
| 0x2 | MMA |
| 0x3 | STORE |
| 0x4 | WAIT |
| 0x5 | REPEAT |

Stride fields ride in a second 64-bit word for LOAD/MMA/STORE when the
`strided` flag bit is set (only REPEAT bodies pay the cost).

## Open questions

- **Multi-shape MMA** — deferred to Phase 10 (re-introduce M/N/K fields).
- **SMEM↔TMEM moves** — not needed for v1 single-kernel matmuls.
- **HW block scaling** — ✅ Phase 8: MXFP8 E8M0 per-block scales (`mx`
  flag + `sa_smem`/`sb_smem`), applied as a fp32 exponent add at drain.
  The actual MMA encoding packs them in the MMA-unused g32/n32 fields +
  bit 140 (see `rtl/cmdproc.sv`).
- **2:4 structured sparsity** — Phase 9: metadata-indexed operand select in
  the MAC cells.
