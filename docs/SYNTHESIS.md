# PtahCore — Synthesis (Phase 5)

First synthesis smoke: every module elaborates through Yosys, no inferred
latches anywhere, and a generic gate-level area baseline for the compute path.

These are **technology-independent generic-gate counts** (Yosys `synth`), a
relative-cost proxy only. Real cell area, timing, and power come from ASAP7
place-and-route in Phase 6.

## Reproduce

```bash
pip install yowasp-yosys
yowasp-yosys -s synth/elaborate.ys   # elaboration + latch assertions (exit 0 = clean)
yowasp-yosys -s synth/area.ys        # per-module gate counts → synth/area.txt
```

## Elaboration / latch check — ✅ PASS

`synth/elaborate.ys` reads all 13 modules, elaborates `chip_top` with
`hierarchy -check` (fails on undriven / multi-driven nets), and asserts
**zero** `$dlatch` / `$_DLATCH_` cells after `proc; opt`. Exit code 0.

No combinational feedback, no unintended latches, no undriven nets.

## Generic gate-level area baseline

| Module | Gates | Notes |
|--------|------:|-------|
| `fp8_decode` | 60 | comb. fp8→fp32, both formats |
| `fp8_encode` | 388 | comb. fp32→fp8 e4m3, RNE+saturate |
| `fp32_add` | 1,627 | IEEE-754 single add, RNE |
| `fp32_mul` | 3,769 | IEEE-754 single mul, RNE |
| **`mac_cell`** (flattened) | **~5,790** | 1× fp32_mul + 1× fp32_add + accumulators |

### Array & chip implications

The MAC grid stamps `mac_cell` **M·N = 1,024** times, so the compute array is
the area driver:

```
array compute ≈ 1024 × 5,790        ≈ 5.9 M generic gates
edge decoders  ≈ (M+N)=64 × 60       ≈ 3.8 K
```

The fp32 multiplier (3,769 gates, ~65% of a MAC cell) is the dominant cost —
expected, and the obvious target for Phase 6+ optimization (a width-reduced or
shared/pipelined FMA, since fp8×fp8 products only need ~16 mantissa bits, not a
full 24×24 multiply).

### What's intentionally excluded

- **SMEM (64 KiB):** a behavioral memory array. Synthesizing it to flip-flops
  is both wrong (it's an **SRAM macro** at hardening) and enormous (it OOM-ed
  the WASM Yosys build). It's elaborated and latch-checked, just not gate-mapped.
- **Full-chip flatten:** dominated by the above; per-module counts are the
  meaningful area signal until ASAP7 P&R gives real numbers.

## Next (Phase 6)

- ASAP7 7nm: synth → floorplan → P&R → GDSII for `mac_cell` first (the tile
  that abuts 1,024×), then the array, then `chip_top`.
- Real timing closure with a traveling clock from day one — the discipline that
  the prior-art chip never achieved (it masked hold violations at chip scale).
- Width-reduced fp8 multiplier to cut the MAC-cell area.
