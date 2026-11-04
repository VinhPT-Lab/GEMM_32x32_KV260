#!/bin/bash
# Run one OpenROAD script (Tcl, or Python with openroad -python) in the LibreLane
# 3.0.16 image. usage: nor.sh <container name> <script> <log> [VAR=value ...]
source "$(dirname "$0")/env.sh"
name=$1; script=$2; log=$3; shift 3
envs=(); for e in "$@"; do envs+=(-e "$e"); done
py=(); [[ $script == *.py ]] && py=(-python)
exec /usr/bin/time -f "PROBE wall %e s" docker run --rm --name "$name" "${DOCKER_COMMON[@]}" "${envs[@]}" \
    "$LIBRELANE_IMAGE" openroad -exit -no_init "${py[@]}" "$script" > "$log" 2>&1
