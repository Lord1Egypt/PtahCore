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
| `mac_cell` (combinational MAC) | ⚠️ placed, fails 250 MHz | 250 MHz | −2237 ps | 833 µm² | 49% | Phase 6a baseline |
| `mac_cell` (pipelined mul+add) | ⚠️ placed, closer but not closed | 250 MHz | **−1309 ps** | **820 µm²** | 48% | Phase 6b — critical path moved to the adder |
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

### Phase 6b update — pipelined MAC (2026-06-11)

Pipelined the MAC cell in two ways, both kept **bit-exact** (89 tests green):
1. Split multiply ↔ add into separate pipeline stages.
2. Pipelined `fp32_mul` itself — registered the 24×24 product before
   normalize/round (latency 1).

The array absorbs the +1 latency with a flush cycle; result values are
unchanged.

**Result:** worst setup slack improved **−2237 → −1309 ps**, area 833 → 820 µm².
But it still doesn't close, and the post-place report pinpoints why: the
critical path is now **`slot_q → acc`** — the **`fp32_add` normalization**
(leading-one priority encoder + variable shift + round), ~5.31 ns at ASAP7.
Pipelining the multiply revealed the adder as the co-critical path.

**Next (Phase 6c):** pipeline `fp32_add` too — split alignment+add from
normalize+round (one more latency cycle through the array). With both fp32
units pipelined, each stage is ~2.6 ns and the cell closes 250 MHz. The
deeper win noted in docs/SYNTHESIS.md still stands: a **width-matched fp8
multiplier** (operands carry ≤4 mantissa bits, not 24) would shrink the cell
and shorten stage 1 substantially — a candidate Phase 7 microarchitecture
change.

ASAP7 is a *predictive, deliberately pessimistic* PDK; these ns figures are
relative-honest, not a foundry guarantee — but the closure discipline is the
same either way.

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
