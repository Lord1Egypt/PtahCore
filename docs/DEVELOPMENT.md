# PtahCore — Development Guide

**Read this before writing code.** Workflow, conventions, and the tribal
knowledge that keeps the build green.

## The build philosophy

1. **pymodel-first.** Behavior is proven in Python before a line of RTL
   exists. The pymodel module docstring IS the spec; the RTL implements it.
2. **Bit-exact or it didn't happen.** Every numeric path is verified
   bit-for-bit against numpy float32 / the golden fp8 model. No tolerances
   in RTL tests — `assert got == want` on raw bits.
3. **config.py is law.** Never hardcode a dimension. Python imports it; RTL
   Makefiles shell out to it for Verilator `-G` flags.
4. **One PR per coherent step.** Branch → PR → merge, CI green before merge.
   STEPS.md is ticked in the same PR that completes the work.

## Layout

```
config.py            ← every parameter, single source of truth
golden/              ← bit-exact fp8 + matmul reference (pure numpy)
pymodel/             ← cycle-level behavioral model + tests
rtl/                 ← SystemVerilog + cocotb testbenches (rtl/tb/)
docs/                ← you are here
PLAN.md / STEPS.md   ← roadmap contract + live checklist
```

## Running tests

```bash
# Python side (golden + pymodel) — no HW tools needed
pip install numpy pytest
pytest                      # 37+ tests, < 1 s

# RTL side — needs Verilator ≥ 5 and cocotb ≥ 2
sudo apt-get install verilator
pip install cocotb
cd rtl/tb
make TOP=fp8_decode         # one unit
make all_leaves             # every leaf in sequence
```

Each cocotb run leaves `dump.vcd`/`.fst` traces in `rtl/tb/sim_build/` —
open with GTKWave when debugging.

## RTL conventions

- `` `default_nettype none `` at the top of every file, `wire` restored at
  the bottom. Undeclared-net typos become compile errors.
- `always_comb` / `always_ff` only — no bare `always`.
- Every `always_comb` assigns every variable on every path (default-assign
  block at the top). Inferred latches are build failures.
- Port names avoid Python keywords (`in8`, not `in`) — cocotb accesses
  ports as attributes.
- One module per file, file named after the module.
- Comments explain *why* and the numeric contract, not what the code does.

## Verification conventions

- The cocotb TB for module X mirrors `pymodel/tests/test_X.py` — same
  scenarios, same seeds where possible, plus RTL-specific cases (reset,
  enable-low holds state, X-propagation at boundaries).
- Arithmetic units get **exhaustive** tests where the space allows
  (fp8_decode: all 512 format×byte combinations) and stratified random +
  directed edges where it doesn't (fp32_add: cancellation, carry, RNE ties,
  signed zeros, inf/NaN, huge alignment distances).
- Drive inputs after a falling edge or use registered handshakes; sample
  outputs after `RisingEdge`. Never race the clock.

## Numeric contracts (memorize these)

- fp8 products are **exact** in fp32 (≤ 9 mantissa bits needed; fp32 has 24).
- Accumulation order is **sequential k = 0..K-1** — pymodel, golden, and RTL
  all share it, which is why bit-exactness is even possible.
- Subnormal fp32 never occurs in the datapath: the smallest decoded fp8
  magnitude is 2⁻¹⁶, the smallest product 2⁻³², both far above 2⁻¹²⁶.
  `fp32_mul`/`fp32_add` document (and the TBs respect) this exclusion.
- e4m3 has **no infinity** — overflow saturates to ±448 at encode time.
  e5m2 keeps ±inf. STORE's fp8 output path uses golden `encode` semantics:
  round-to-nearest-even, saturating.

## Debugging discipline

1. Reproduce in the **pymodel** first if possible — Python debugging beats
   waveform archaeology.
2. If RTL-only: minimize the failing case in the cocotb TB (binary-search
   the seed/index), THEN open the waves.
3. Every fixed bug gets a regression test in the same PR as the fix.
4. Never weaken an assertion to make a test pass. Tolerances are for
   float64-vs-float32 comparisons in golden tests only — RTL is bit-exact.

## Adding a new module (checklist)

1. Spec docstring in the pymodel file (INPUTS/OUTPUTS/STATE/BEHAVIOR/INVARIANTS).
2. pymodel implementation + `pymodel/tests/test_<mod>.py`.
3. e2e impact: extend `pymodel/tests/test_e2e.py` if the ISA surface changed.
4. RTL twin in `rtl/<mod>.sv` + cocotb TB in `rtl/tb/test_<mod>.py`.
5. Wire into `rtl/tb/Makefile` (and `all_leaves`).
6. Tick STEPS.md, update docs touched by the change, PR.
