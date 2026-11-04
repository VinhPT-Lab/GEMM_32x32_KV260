#!/bin/bash
# Run one OpenROAD Tcl script in the OpenLane 1.0.2 image (OpenROAD 41a51eaf), e.g.
# drv_plan.tcl or sta6b.tcl. Paths given in VAR=value are mounted when they exist.
# usage: olor.sh <container name> <script.tcl> <log> [VAR=value ...]
source "$(dirname "$0")/env.sh"
name=$1; script=$2; log=$3; shift 3
envs=(); mounts=()
for e in "$@"; do
  envs+=(-e "$e"); v=${e#*=}
  [ -e "$v" ] && { d=$(realpath "$v"); [ -d "$d" ] || d=$(dirname "$d"); mounts+=(-v "$d:$d"); }
done
exec docker run --rm --name "$name" "${DOCKER_COMMON[@]}" "${mounts[@]}" "${envs[@]}" \
    "$OL_IMAGE" openroad -exit "$script" > "$log" 2>&1
