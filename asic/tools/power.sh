#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Power of a finished core run at tt/25C/1.80V, 100 MHz (OpenSTA in the OpenLane image).
#
#   tools/power.sh [<core run dir>]                 default activity of OpenSTA (vectorless)
#   tools/power.sh [<core run dir>] --vcd C0 C1     activity from a gate-level sim: shape
#                                                   64,64,64 with the row gate netlist, nets
#                                                   dumped for testbench cycles [C0, C1)
#                                                   (2300 3200 = compute phase of job 2)
# Rows: gate netlist + SPEF of ROW_RUN [$OL/designs/gemm_row/runs/row_v1].
# The complete IP (a gemm_ip run): DESIGN=GEMM_top SHELL_RUN=<gemm_ip_shell run>
#   tools/power.sh <gemm_ip run>  (vectorless only; the AXI macro as its gate netlist + SPEF)
# SRAM: OpenRAM .lib, same energy on every clock edge whether selected or not.
# Output: <run>/reports/power/{vectorless,vcd_C0_C1}.{design,inst,groups}.* (POWER_OUT=dir to write
# elsewhere, e.g. to leave a finished run untouched; POWER_BUILD=dir for the simulation)
# Needs ~8 GB RAM (STA) and, with --vcd, ~7 GB for the simulation, ~0.7 GB disk per 1000 cycles.
# ---------------------------------------------------------------------------
set -euo pipefail
KIT=$(cd "$(dirname "$0")/.." && pwd)
OL=${OL:-$HOME/OpenLane}
REPO=${REPO:-$KIT/../GEMM_32x32_KV260-main}
IMG=${OL_IMAGE:-ghcr.io/the-openroad-project/openlane:ff5509f65b17bfa4068d5336495ab1718987ff69-amd64}
# RAM limit as openlane/run_flow.sh (DOCKER_MEMORY / DOCKER_SWAP, empty = none)
MEM=()
[ -n "${DOCKER_MEMORY-10g}" ] && MEM+=(--memory="${DOCKER_MEMORY-10g}")
[ -n "${DOCKER_SWAP-40g}" ] && MEM+=(--memory-swap="${DOCKER_SWAP-40g}")
PDK_ROOT=${PDK_ROOT:-$HOME/.ciel}
RUN=""; C0=""; C1=""
while [ $# -gt 0 ]; do
    case "$1" in
        --vcd) C0=${2:?}; C1=${3:?}; shift 3 ;;
        *) RUN=$1; shift ;;
    esac
done
if [ -z "$RUN" ]; then
    RUN=$(ls -td "$OL"/designs/gemm_core/runs/*/results/final/verilog/gl 2>/dev/null | head -1)
    RUN=${RUN%/results/final/verilog/gl}
fi
RUN=$(cd "$RUN" && pwd)
DESIGN=${DESIGN:-GemmAccelerator}
SHELL_RUN=${SHELL_RUN:-}
[ -n "$SHELL_RUN" ] && SHELL_RUN=$(cd "$SHELL_RUN" && pwd)
ROW_RUN=$(cd "${ROW_RUN:-$OL/designs/gemm_row/runs/row_v1}" && pwd)
OUT=${POWER_OUT:-$RUN/reports/power}; mkdir -p "$OUT"
echo "core run: $RUN ($DESIGN)"; echo "row run : $ROW_RUN"
[ -n "$SHELL_RUN" ] && echo "AXI macro run: $SHELL_RUN"

sta_power() {   # sta_power <name> [activity file]
    local env=(-e CORE_FINAL="$RUN/results/final" -e ROW_FINAL="$ROW_RUN/results/final" -e OUT="$OUT/$1" -e PDK_ROOT="$PDK_ROOT"
               -e DESIGN="$DESIGN")
    [ -n "$SHELL_RUN" ] && env+=(-e SHELL_FINAL="$SHELL_RUN/results/final")
    [ -n "${2:-}" ] && env+=(-e ACT="$2")
    docker run --rm "${MEM[@]}" -u "$(id -u):$(id -g)" -v "$HOME:$HOME" -v "$PDK_ROOT:$PDK_ROOT" -v "$KIT:$KIT" -v "$OL:$OL" \
        "${env[@]}" "$IMG" sta -no_splash -exit "$KIT/tools/power/power.tcl" 2>&1 \
        | grep -v "^Warning: .* not found. Creating black box" | tee "$OUT/$1.log"
    python3 "$KIT/tools/power/power_groups.py" "$OUT/$1.inst.rpt" "$OUT/$1.refs.txt" | tee "$OUT/$1.groups.txt"
}

if [ -z "$C0" ]; then
    sta_power vectorless
    exit 0
fi
[ "$DESIGN" = GemmAccelerator ] || { echo "--vcd is written for the core (GemmAccelerator) only"; exit 2; }
name=vcd_${C0}_$C1
B=${POWER_BUILD:-$KIT/sim/build_power}; mkdir -p "$B"
python3 "$KIT/tools/power/vcd_window.py" "$C0" "$C1" "$B/$name.vcd" "$B/vcd_window.v"
echo "gate-level sim (rows: gate netlist), dumping cycles $C0..$C1"
BUILD=$B ROW=gl EXTRA_V=$B/vcd_window.v OL=$OL "$KIT/sim/run_gls.sh" "$RUN" "$REPO" > "$B/run_gls.log" 2>&1 || true
grep -q "VCD_END" "$B/gls.log" || { echo "no VCD_END in $B/gls.log"; tail -5 "$B/gls.log"; exit 1; }
python3 "$KIT/tools/power/vcd2act.py" "$B/$name.vcd" "$RUN/results/final/verilog/gl/GemmAccelerator.nl.v" \
    "$ROW_RUN/results/final/verilog/gl/ProcessingElementRow.nl.v" "$OUT/$name.act"
sta_power "$name" "$OUT/$name.act"
