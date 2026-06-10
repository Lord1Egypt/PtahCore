#!/usr/bin/env bash
# PtahCore — drive an ASAP7 harden through the OpenROAD-flow-scripts image.
#
#   flow/harden.sh mac_cell
#
# Mounts the repo into the ORFS container, points the flow at our design
# config, and runs synth → floorplan → place → CTS → route → finish,
# producing a GDS + reports under flow/results/.
#
# Requires: docker, and the openroad/orfs:latest image
#   (pull with a credential-helper-free config on WSL2/Docker-Desktop:
#    DOCKER_CONFIG=/tmp/dockercfg docker pull openroad/orfs:latest)

set -euo pipefail

DESIGN="${1:-mac_cell}"
REPO="$(cd "$(dirname "$0")/.." && pwd)"
IMAGE="${ORFS_IMAGE:-openroad/orfs:latest}"
DOCKER_CONFIG_DIR="${DOCKER_CONFIG:-$HOME/.docker}"

CFG="/work/flow/designs/asap7/${DESIGN}/config.mk"

echo "▶ Hardening '${DESIGN}' on ASAP7 via ${IMAGE}"
echo "  repo : ${REPO}"
echo "  cfg  : ${CFG}"

DOCKER_CONFIG="${DOCKER_CONFIG_DIR}" docker run --rm \
    -v "${REPO}:/work" \
    -e PTAHCORE=/work \
    -w /OpenROAD-flow-scripts/flow \
    "${IMAGE}" \
    bash -lc "
        source /OpenROAD-flow-scripts/env.sh 2>/dev/null || true
        make DESIGN_CONFIG=${CFG} \
             WORK_HOME=/work/flow \
        && echo '✅ harden finished — see flow/results/'
    "
