# Resume Guide — what's done, what's left (2026-06-14)

This is the live handoff after a **Docker-free design+verification push** on
the cloud box. Everything that did NOT need Docker is done, merged, and
green. What remains is **place-and-route / GDS work** (needs Docker +
OpenROAD/ORFS) plus one optional Docker-free RTL feature. Resume from your
laptop using the ordered steps below.

> Companion docs: `CLOUD_HANDOFF.md` (the 7d-3 P&R flow mechanics & traps —
> still accurate), `STEPS.md` (the full checklist), `docs/HARDENING.md`
> (failure log), `docs/SPARSITY.md` (2:4 design), `docs/ISA.md`.

---

## What this session added (all merged into `feat/phase7d3-chip-flow`)

| PR | Phase | What | Docker? |
|----|-------|------|---------|
| #22 | 8 | MXFP8 microscaling — E8M0 per-block scale, fp32 **exponent-add at drain** (no multiply, MAC cells untouched). golden→pymodel→RTL bit-exact. | no |
| #23 | 9a | 2:4 sparsity format + golden + pymodel — bit-exact + 2× throughput by step count. | no |
| #24 | 9b-i | `sparse_select.sv` — per-cell 2-of-4 mux primitive, verified vs golden. | no |
| #25 | 9b-ii | `mac_array_sparse.sv` — full 2:4 sparse compute datapath in RTL (K/2 steps, reuses untouched `mac_cell`), bit-exact. | no |
| #26 | 10 | 64×64 config scalability — pymodel (`test_scale.py`). | no |
| (this) | 10 | 64×64 config — **RTL** evidence: `synth/lint_64.sh` (verilator lint of mac_array/mma_unit/chip_top at MMA_M=N=K=64) + `make sim TOP=mac_array_big` (bit-exact sim at non-native 64×4×64, M&K past 32). | no |

**`mx=0` and `sparse=0` are bit-identical to the pre-Phase-8 design**, so the
five existing GDS paths are undisturbed by the RTL changes.

## Current verified state (Docker-free, reproduce in seconds)

```bash
pip install "cocotb<2" yowasp-yosys numpy pytest   # + apt-get install verilator (5.020)
export LANG=C.UTF-8 PYTHONIOENCODING=utf-8          # silence em-dash logger noise
cd rtl/tb && make all_leaves        # 20 RTL units, 73 cocotb tests, FAIL=0
make sim TOP=mac_array_big          # bit-exact RTL sim at non-native 48×48×16
cd ../.. && pytest golden pymodel -q # 102 Python tests
yowasp-yosys -s synth/elaborate.ys  # elaborates clean, no inferred latches
sh synth/lint_64.sh                  # RTL lints CLEAN at 64×64×64 (3 tops)
```
Trust `rtl/tb/check_results.py` / the `PASS=/FAIL=` line, not the make exit
code (cocotb 1.x exits 0 on failures).

---

## Remaining work — DOCKER (do these on your laptop)

All P&R/GDS. The toolchain is the `openroad/orfs:latest` image; flow mechanics,
the NUM_CORES knob, the harden scripts, and every trap already solved are in
`CLOUD_HANDOFF.md` + `docs/HARDENING.md`. **Re-verify RTL green first** (above).

1. **Phase 7d-3 — the 6th GDS (`chip_top`)** — finish what the cloud handoff
   was about: `flow/harden_grid.sh` then `flow/harden_chip.sh` (the
   dont_touch DPL fix `67929fd` + the launch-clock model). This is unchanged
   by this session's work (mx=0/sparse=0 paths are bit-identical). See
   `CLOUD_HANDOFF.md` "TL;DR".

2. **Phase 8 GDS** — re-harden `chip_top` with the `mx_scale` block on the
   drain/store path. `mx_scale.sv` is small + combinational (exponent add +
   saturate) and sits between the array drain and the fp8 encode / fp32
   write in `store.sv` — verify it doesn't blow the store/drain timing
   (it's a handful of gates). Add it to the chip RTL list if not picked up
   automatically. Re-run signoff; record in `docs/HARDENING.md`.

3. **Phase 9b-iii + Phase 9 GDS** — fold the proven per-cell 2-of-4 select
   into the **abutted** tile: widen `mac_tile`'s B feedthrough 1→4 lanes and
   route `meta_sel` east with the A wave (TILE_SPEC pin-contract change → new
   abstract). Start from the verified `mac_array_sparse.sv` datapath +
   `sparse_select.sv` + the golden/pymodel reference; hold `sparse=0`
   bit-identical. Full design rationale in `docs/SPARSITY.md` (§"9b-iii").
   Then re-harden tile → grid → chip. This is the one piece that reshapes
   the physical tile, which is why it's bundled here.

4. **64×64 config GDS** — bump `config.MMA_M/N/K` (RTL side proven by
   `test_scale.py`) and re-run P&R at the larger array. Expect more RAM/time;
   the abutment/traveling-clock thesis is shape-independent.

5. **Phase 7e — GDS web viewer + gallery** — render the `6_final.gds`
   artifacts (KLayout, headless: `QT_QPA_PLATFORM=offscreen klayout -z -nc
   -r script.py`) and deploy the 2D/3D viewer. Needs the GDS artifacts, so
   it follows the harden runs.

## Remaining work — DOCKER-FREE (optional, can be done anywhere)

- **Phase 10: multi-shape MMA** — a *per-instruction* runtime shape (M/N/K ≤
  native, mask the surplus rows/cols/K-steps): ISA operand fields back +
  cmdproc decode + mma_unit/array masking, `shape=full` bit-identical. NOT
  started this session (scoped out to keep the tree clean). The next clean
  Docker-free task. (Config-time reshape to 64×64 is already proven by
  `test_scale.py`; this is the orthogonal per-op feature.)
- **Blog-style writeup** — Docker-free; the gallery images need the GDS.

---

## Key new files this session

- `golden/mxfp8.py`, `golden/sparse24.py` — bit-exact references
- `rtl/mx_scale.sv` — MXFP8 drain exponent-add+saturate
- `rtl/sparse_select.sv` — 2:4 per-cell 2-of-4 mux
- `rtl/mac_array_sparse.sv` — 2:4 sparse compute datapath (K/2 steps)
- `pymodel/tests/test_scale.py` — 64×64 config scalability
- `docs/SPARSITY.md` — the 2:4 architecture + the 9b-iii integration spec
- config.py — MXFP8 params (E8M0_BIAS/NAN, scale byte counts)
