#!/bin/bash
# sta6b.tcl for one layout, every lib corner x RC corner, one run at a time
# (OpenROAD of OpenLane 1.0.2, read-only). Output: $ECO_DIR/sta6b/<DES>_<corner>_<rc>.*
# usage: sta6b_one.sh <DES> <odb> <mca dir of an OL1 run (process_corner_*/GEMM_top.spef)>
#        DES=v3r reads $V3R_ODB and $ECO_DIR/in/GEMM_top.<rc>.spef instead
source "$(dirname "$0")/env.sh"
DES=$1; ODB=$(realpath "$2"); MCA=$(realpath "$3"); mkdir -p "$ECO_DIR/sta6b"
extra=(-v "$(dirname "$ODB"):$(dirname "$ODB")" -v "$MCA:$MCA")
if [ -n "${V3R_ODB:-}" ]; then V3R_ODB=$(realpath "$V3R_ODB"); extra+=(-v "$(dirname "$V3R_ODB"):$(dirname "$V3R_ODB")" -e V3R_ODB="$V3R_ODB"); fi
for C in tt ff ss; do for RC in min nom max; do
  log=$ECO_DIR/sta6b/${DES}_${C}_$RC.log
  docker run --rm --name sta6b "${DOCKER_COMMON[@]}" "${extra[@]}" -e DES="$DES" -e C=$C -e RC=$RC -e DRV=1 -e EXTRA="${EXTRA:-0}" \
    -e ECO_ODB="$ODB" -e ECO_SPEF_DIR="$MCA" "$OL_IMAGE" openroad -exit "$ECO_TOOLS/sta6b.tcl" > "$log" 2>&1
  grep -E "^STA6B|\[ERROR|^Error" "$log"
  a=$(df -BG --output=avail "$ECO_DIR" | tail -1 | tr -dc 0-9); [ "$a" -lt 10 ] && { echo "DISK LOW $a G"; exit 1; }
done; done
echo STA6B_DONE
