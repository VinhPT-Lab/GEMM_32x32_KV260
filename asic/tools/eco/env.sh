# Settings shared by the tools/eco shell scripts (sourced, not run).
#   ECO_DIR          work directory: in/ (DEF, netlists, SDC, SPEF of the source run),
#                    lef/ and lib/ (macro views), and every output of the ECO steps
#   PDK_ROOT         PDK of the OpenLane 1.0.2 flow (sky130A under it), never the image's
#   OL               OpenLane 1.0.2 checkout (flow.tcl, designs/)
#   LIBRELANE_IMAGE  LibreLane 3.0.16, amd64, pinned by digest; its OpenROAD is
#                    dcf36133a369abc8f3c5e5738cd4d82e4903c0e0 (2026-02-17)
#   OL_IMAGE         OpenLane 1.0.2 image (OpenROAD 41a51eaf)
#   DOCKER_MEMORY / DOCKER_SWAP   container RAM limits, as openlane/run_flow.sh
: "${ECO_DIR:?set ECO_DIR to the ECO work directory}"
: "${PDK_ROOT:?set PDK_ROOT (the PDK of the OpenLane 1.0.2 flow)}"
LIBRELANE_IMAGE=${LIBRELANE_IMAGE:-ghcr.io/librelane/librelane@sha256:4bc9042ba177f73f275b5b39e7d372a07d3f4043f548a0ba7f640097b7205051}
OL_IMAGE=${OL_IMAGE:-ghcr.io/the-openroad-project/openlane:ff5509f65b17bfa4068d5336495ab1718987ff69-amd64}
DOCKER_MEMORY=${DOCKER_MEMORY:-10g}
DOCKER_SWAP=${DOCKER_SWAP:-40g}
ECO_TOOLS=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ECO_DIR=$(cd "$ECO_DIR" && pwd)
PDK_ROOT=$(cd "$PDK_ROOT" && pwd)
export ECO_DIR PDK_ROOT ECO_TOOLS
# docker options common to every container: user, RAM limits, mounts, environment
DOCKER_COMMON=(--user "$(id -u):$(id -g)" --memory="$DOCKER_MEMORY" --memory-swap="$DOCKER_SWAP"
    -v "$ECO_DIR:$ECO_DIR" -v "$PDK_ROOT:$PDK_ROOT" -v "$ECO_TOOLS:$ECO_TOOLS"
    -e ECO_DIR="$ECO_DIR" -e PDK_ROOT="$PDK_ROOT" -e ECO_TOOLS="$ECO_TOOLS")
