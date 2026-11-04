#!/bin/bash
# Run an OpenLane 1.0.2 interactive script (docker options as OpenLane's Makefile).
# usage: ol.sh <container name> <script.tcl> <log> [VAR=value ...]
source "$(dirname "$0")/env.sh"
: "${OL:?set OL to the OpenLane 1.0.2 directory}"
OL=$(cd "$OL" && pwd)
name=$1; script=$2; log=$3; shift 3
envs=(); for e in "$@"; do envs+=(-e "$e"); done
cd "$OL"
exec /usr/bin/time -f "PROBE wall %e s" docker run --rm --name "$name" "${DOCKER_COMMON[@]}" "${envs[@]}" \
    -v "$OL:/openlane" -v "$OL/designs:/openlane/install" -e PDK=sky130A -e ROUTING_CORES="${ROUTING_CORES:-8}" \
    -w /openlane "$OL_IMAGE" sh -c "./flow.tcl -interactive -file $script" > "$log" 2>&1
