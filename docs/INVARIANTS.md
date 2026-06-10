# PtahCore — Build & Hardening Invariants

Statements that must always hold. Each has a **how to check** so it's a
test, not a hope. Borrowed discipline: if an invariant can't be checked
mechanically, it isn't an invariant yet.

## RTL invariants

| # | Invariant | How to check |
|---|-----------|--------------|
| R1 | Every module elaborates with no undriven/multi-driven nets | `yowasp-yosys -s synth/elaborate.ys` (`hierarchy -check`) |
| R2 | No inferred latches anywhere | same script, `select -assert-none t:$dlatch t:$_DLATCH_` (exit ≠ 0 on violation) |
| R3 | Every numeric path is bit-exact vs golden/numpy | `cd rtl/tb && make all_leaves` (52 RTL tests, `==` on raw bits) |
| R4 | All dimensions derive from `config.py` | grep RTL for literal `32`/`16` outside config-fed params; none in datapath |
| R5 | Sim-only assertions never synthesize | every `assert`/`$fatal` is inside `` `ifndef SYNTHESIS `` |

## Build-flow invariants

| # | Invariant | How to check |
|---|-----------|--------------|
| B1 | Hardening is idempotent — re-running produces the same GDS | hash `6_final.gds` across two runs |
| B2 | Parents are abutment-only over hardened macros — no wire crosses a tile | LEF obstruction check on the array floorplan |
| B3 | A tile's `.lib` is characterised under the parent's clock-entry model | compare CTS assumptions in tile vs. parent (TILE_SPEC §6) |
| B4 | No timing signoff with masked hold — `HOLD_SLACK_MARGIN ≥ 0` | grep flow configs; **negative hold margin is banned** (the prior-art chip's cardinal sin) |
| B5 | Reported slack is real — no multicycle/false-path workaround hiding a true violation | every exception in an `.sdc` cites a structural reason on the same line |

## The one that matters most

**B4 is non-negotiable.** The entire thesis of PtahCore vs. the prior art
is *honest* timing closure. A chip that only "closes" because hold
violations were masked with a negative slack margin is a functional-
failure-class part (data captured before it's valid). If a tile or the
chip can't close hold at the target frequency, the answer is to fix the
design or lower the frequency — never to hide the violation.

When ASAP7 P&R starts producing numbers, each closed block is recorded in
`docs/HARDENING.md` with its **real** worst slack, DRC count, and the
exact flow settings used — no asterisks.
