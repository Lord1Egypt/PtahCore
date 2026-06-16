#!/usr/bin/env bash
# PtahCore — Phase 7d: harden chip_top (the whole accelerator).
#
# The grid macro's artifacts (lef / typ.lib / 6_final.gds) must exist
# from a harden_grid.sh run — they are consumed via ADDITIONAL_* (the
# riscv32i-mock-sram pattern), NOT rebuilt here. The abstract lesson:
# a later `make generate_abstract` re-runs the whole flow, so if the
# lib is missing, rebuild the grid with harden_grid.sh (which chains
# block → abstract → patch → grid in one make invocation).
#
#   DOCKER_CONFIG=/tmp/dockercfg ORFS_MAKE_ARGS='NUM_CORES=6' flow/harden_chip.sh

set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
IMAGE="${ORFS_IMAGE:-openroad/orfs:latest}"
DOCKER_CONFIG_DIR="${DOCKER_CONFIG:-$HOME/.docker}"
MAKE_ARGS="${ORFS_MAKE_ARGS:-}"

GRID=${REPO}/flow/results/asap7/mac_grid/base
for f in mac_grid.lef mac_grid_typ.lib 6_final.gds; do
    if [ ! -f "${GRID}/$f" ]; then
        echo "✗ missing grid artifact ${GRID}/$f — run flow/harden_grid.sh" \
             "(plus 'make generate_abstract' chained inside it) first"
        exit 1
    fi
done

DOCKER_CONFIG="${DOCKER_CONFIG_DIR}" docker run --rm \
    ${DOCKER_MEM_ARGS:-} \
    -v "${REPO}:/work" -e PTAHCORE=/work \
    -w /OpenROAD-flow-scripts/flow "${IMAGE}" \
    bash -lc "source /OpenROAD-flow-scripts/env.sh 2>/dev/null || true
              make DESIGN_CONFIG=/work/flow/designs/asap7/chip_top/config.mk \
                   WORK_HOME=/work/flow ${MAKE_ARGS} $*"

echo "✅ chip_top $* done — see flow/results/asap7/chip_top/"
