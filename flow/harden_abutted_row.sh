#!/usr/bin/env bash
# PtahCore — Phase 7b-3: harden the abutted traveling-clock row.
#
# The row consumes mac_tile's characterised .lib — but write_timing_model
# encodes the clk_in→clk_out feedthrough as a falling_edge arc, which
# OpenSTA refuses to propagate a clock through (tiles 1–31 end up
# silently unconstrained). The patch step rewrites it combinational
# (flow/patch_tile_clk_arc.py) and MUST land between the block's
# abstract generation and the parent's synthesis — hence this
# orchestrator instead of a bare flow/harden.sh call:
#
#   1. harden the mac_tile block + generate its abstract
#   2. patch the clk arc in the generated .lib
#   3. harden the row top (block dependency now up to date → reuses
#      the patched abstract)
#
#   ORFS_MAKE_ARGS='NUM_CORES=6' flow/harden_abutted_row.sh

set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
IMAGE="${ORFS_IMAGE:-openroad/orfs:latest}"
DOCKER_CONFIG_DIR="${DOCKER_CONFIG:-$HOME/.docker}"
MAKE_ARGS="${ORFS_MAKE_ARGS:-}"

BLOCK_CFG=/work/flow/designs/asap7/mac_row_abut/mac_tile/config.mk

run_make() {
    DOCKER_CONFIG="${DOCKER_CONFIG_DIR}" docker run --rm \
        -v "${REPO}:/work" -e PTAHCORE=/work \
        -w /OpenROAD-flow-scripts/flow "${IMAGE}" \
        bash -lc "source /OpenROAD-flow-scripts/env.sh 2>/dev/null || true
                  make DESIGN_CONFIG=$1 WORK_HOME=/work/flow ${MAKE_ARGS} $2"
}

echo "▶ [1/3] mac_tile block + abstract"
run_make "${BLOCK_CFG}" ""
run_make "${BLOCK_CFG}" "generate_abstract"

echo "▶ [2/3] patch clk_in→clk_out arc (STA clock propagation)"
docker run --rm -v "${REPO}:/work" "${IMAGE}" \
    python3 /work/flow/patch_tile_clk_arc.py \
    /work/flow/results/asap7/mac_row_abut_mac_tile/base/mac_tile_typ.lib

echo "▶ [3/3] abutted row"
"${REPO}/flow/harden.sh" mac_row_abut

echo "✅ abutted row done — verify: clock propagation per tile,"
echo "   flow/check_abutment.py, and flow/reports/.../6_finish.rpt"
