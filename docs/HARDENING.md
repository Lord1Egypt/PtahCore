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

| Block | Status | Clock | Worst setup | Area | Util | Notes |
|-------|--------|-------|------------|------|------|-------|
| `mac_cell` | ⚠️ placed; **fails timing at 250 MHz**; CTS blocked | 250 MHz (4.0 ns) | **−2237 ps** (post-place) | **833 µm²** | 49% | real ASAP7 numbers — see finding below |
| row (1×N) | ⬜ | — | — | — | — | after mac_cell closes |
| array (32×32) | ⬜ | — | — | — | — | — |
| `chip_top` | ⬜ | — | — | — | — | — |

_(Pre-layout generic-gate area baselines are in docs/SYNTHESIS.md.)_

### First-run findings (2026-06-11, ASAP7, real P&R)

The flow ran **synth → floorplan → placement** clean on real ASAP7, giving the
first true silicon-level numbers:

- **Area:** one `mac_cell` is **833 µm²** at 49% utilisation.
- **Timing — the real finding:** the cell **does not close at 250 MHz**.
  Post-placement worst setup slack is **−2237 ps** on the accumulator-input
  path. The critical path is the **single-cycle fp32 multiply → fp32 add →
  accumulator** chain: ~6.24 ns of logic, so the unpipelined cell tops out at
  **≈ 160 MHz** at 7nm. This matches the pre-layout signal that `fp32_mul`
  dominates the cell (docs/SYNTHESIS.md).

  **This is honest data, not a number to mask** (docs/INVARIANTS.md §B4).
  The fix is a real design change, scheduled as Phase 6b: **pipeline the MAC
  cell** — register between the multiply and the add (and propagate the extra
  latency through `mac_array`'s K-loop, the pymodel, and the tests so it stays
  bit-exact). A pipelined fp32 multiply + a pipelined add comfortably hits
  250 MHz; the accumulator feedback add is the only single-cycle path left and
  it's well under 4 ns alone.

## Failure log

Every distinct flow error hit, with root cause + fix, so it's never
re-debugged from scratch.

| Error / symptom | Block | Root cause | Fix |
|-----------------|-------|-----------|-----|
| `read_verilog`: "File `SYNTHESIS' not found" | mac_cell | ORFS default Yosys frontend needs `-D` prefix on defines | `VERILOG_DEFINES = -DSYNTHESIS` (not `SYNTHESIS`) |
| SDC: `invalid command name "remove_from_collection"` | mac_cell | OpenROAD's SDC reader lacks `remove_from_collection` | list data ports explicitly in `set_input_delay` |
| `cts.tcl: child killed: illegal instruction` (SIGILL) | mac_cell | TritonCTS child process hits a CPU instruction the WSL2 VM lacks (prebuilt OpenROAD binary, AVX-class) — environment, not design | blocked here; needs a native OpenROAD build or an AVX-capable host to complete CTS→route→GDS. Synth/floorplan/place numbers above are unaffected. |

## Failure log

Every distinct flow error hit, with root cause + fix, so it's never
re-debugged from scratch. (Empty until the first real P&R run; this is
where ASAP7 PDK gaps, antenna/IR/DRC issues, and abutment problems get
written down once.)

| Error / symptom | Block | Root cause | Fix |
|-----------------|-------|-----------|-----|
| _(none yet)_ | | | |
