#!/bin/bash
# RCX + STA (9 corners) + clock pin dump (TT nom, SS max) for one layout: OL1 import,
# ARC and RCX (s5_ol.tcl, rcx mode), sta6b_one.sh, clk_scope.tcl.
# usage: [OUTD=dir] check_layout.sh <tag> <def>      (OUTD under $ECO_DIR, default s7B)
source "$(dirname "$0")/env.sh"
cd "$ECO_DIR"; T=$1; D=$(realpath "$2"); O=${OUTD:-s7B}; mkdir -p "$O"
"$ECO_TOOLS/ol.sh" s6crcx "$ECO_TOOLS/s5_ol.tcl" "$ECO_DIR/$O/$T.rcx.log" S5_DEF="$D" S5_TAG=${T}_sta S5_MODE=rcx
grep -E "probe:|\[ERROR" "$O/$T.rcx.log"
grep -q "RCX + STA done" "$O/$T.rcx.log" || { echo RCX_FAILED; exit 1; }
M=$ECO_DIR/s5/${T}_sta/results/routing
"$ECO_TOOLS/sta6b_one.sh" "$T" "$M/GEMM_top.odb" "$M/mca"
for cr in "tt nom" "ss max"; do set -- $cr
  docker run --rm --name clkscope "${DOCKER_COMMON[@]}" -e C=$1 -e RC=$2 -e ODB="$M/GEMM_top.odb" \
    -e SPEF="$M/mca/spef/GEMM_top.$2.spef" -e OUTF="$ECO_DIR/$O/${T}_$1_$2.clk.tsv" \
    "$OL_IMAGE" openroad -exit "$ECO_TOOLS/clk_scope.tcl" > "$O/${T}_$1_$2.clk.log" 2>&1
  grep -E "CLKSCOPE|\[ERROR" "$O/${T}_$1_$2.clk.log"
done
echo CHECK_DONE
