#!/usr/bin/env bash
# PtahCore — Phase 7c: harden the 32×32 abutted traveling-clock array.
#
# Same orchestration as harden_abutted_row.sh and for the same reason:
# write_timing_model encodes the tile's clk_in→clk_out feedthrough as a
# falling_edge arc, which OpenSTA refuses to propagate a clock through —
# without the patch step 1023 of 1024 tiles are SILENTLY unconstrained
# (the false-clean trap, docs/HARDENING.md). Order:
#
#   1. harden the mac_tile block + generate its abstract
#   2. patch the clk arc in the generated .lib (MANDATORY)
#   3. harden the grid top (reuses the patched abstract)
#
#   ORFS_MAKE_ARGS='NUM_CORES=6' flow/harden_grid.sh
#
# After it finishes: flow/check_abutment.py (2D), and verify in
# 6_finish reports that capture-clock arrival grows ~δs per row and
# ~δe per column, non-inverted (ARRAY_SPEC §2 honesty check).

set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
IMAGE="${ORFS_IMAGE:-openroad/orfs:latest}"
DOCKER_CONFIG_DIR="${DOCKER_CONFIG:-$HOME/.docker}"
MAKE_ARGS="${ORFS_MAKE_ARGS:-}"

BLOCK_CFG=/work/flow/designs/asap7/mac_grid/mac_tile/config.mk

run_make() {
    DOCKER_CONFIG="${DOCKER_CONFIG_DIR}" docker run --rm \
        -v "${REPO}:/work" -e PTAHCORE=/work \
        -w /OpenROAD-flow-scripts/flow "${IMAGE}" \
        bash -lc "source /OpenROAD-flow-scripts/env.sh 2>/dev/null || true
                  make DESIGN_CONFIG=$1 WORK_HOME=/work/flow ${MAKE_ARGS} $2"
}

echo "▶ [1/4] mac_tile block + abstract"
run_make "${BLOCK_CFG}" ""
run_make "${BLOCK_CFG}" "generate_abstract"

echo "▶ [2/4] patch clk_in→clk_out arc (STA clock propagation)"
docker run --rm -v "${REPO}:/work" "${IMAGE}" \
    python3 /work/flow/patch_tile_clk_arc.py \
    /work/flow/results/asap7/mac_grid_mac_tile/base/mac_tile_typ.lib

echo "▶ [3/4] 32×32 abutted array"
"${REPO}/flow/harden.sh" mac_grid

echo "▶ [4/4] grid abstract for chip_top (exact M6/M7 OBS — PDN-0006)"
run_make "/work/flow/designs/asap7/mac_grid/config.mk" "generate_abstract"
DOCKER_CONFIG="${DOCKER_CONFIG_DIR}" docker run --rm \
    -v "${REPO}:/work" "${IMAGE}" \
    bash -lc "source /OpenROAD-flow-scripts/env.sh 2>/dev/null || true
              cd /work/flow/results/asap7/mac_grid/base &&
              cp mac_grid.lef mac_grid_bloat.lef.bak &&
              openroad -no_init -no_splash -exit /work/flow/exact_abstract.tcl &&
              python3 /work/flow/exact_obs_lef.py mac_grid_exact.lef mac_grid.lef \
                  --exact-layers M7"

echo "✅ grid done — now: flow/check_abutment.py (2D),"
echo "   per-tile clock arrivals in flow/reports/asap7/mac_grid/base/6_finish*.rpt"
