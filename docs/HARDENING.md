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

| Block | Status | Clock | Worst setup | Worst hold | DRC | Area | Notes |
|-------|--------|-------|------------|-----------|-----|------|-------|
| `mac_cell` | ⏳ pending first run | 250 MHz target | — | — | — | — | config + constraints ready (`flow/designs/asap7/mac_cell/`) |
| row (1×N) | ⬜ | — | — | — | — | — | after mac_cell closes |
| array (32×32) | ⬜ | — | — | — | — | — | — |
| `chip_top` | ⬜ | — | — | — | — | — | — |

_(Pre-layout generic-gate area baselines are in docs/SYNTHESIS.md.)_

## Failure log

Every distinct flow error hit, with root cause + fix, so it's never
re-debugged from scratch. (Empty until the first real P&R run; this is
where ASAP7 PDK gaps, antenna/IR/DRC issues, and abutment problems get
written down once.)

| Error / symptom | Block | Root cause | Fix |
|-----------------|-------|-----------|-----|
| _(none yet)_ | | | |
