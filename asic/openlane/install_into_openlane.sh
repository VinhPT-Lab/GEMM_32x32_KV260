#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Copy the ASIC RTL and the four design configs into an OpenLane v1 tree.
# usage: openlane/install_into_openlane.sh /path/to/OpenLane [--pe-area <um^2>] [gen args...]
#   --pe-area: regenerate sizes.tcl / pin_order.cfg / macro.cfg from the PE
#              area measured in the gemm_pe run (default: 6560, from your
#              PE_Array synthesis: 7.17 mm^2 minus skew/deskew, / 1024)
# Re-run it every time you change RTL or sizes; it overwrites src/ copies but
# never touches runs/.
# ---------------------------------------------------------------------------
set -euo pipefail
OL=${1:?give the path to the OpenLane directory (the one with flow.tcl)}
shift
PE_AREA=6560
if [ "${1:-}" = "--pe-area" ]; then PE_AREA=${2:?}; shift 2; fi
# anything left (e.g. --util 0.45 --gap 30) goes to gen_openlane_files.py

KIT=$(cd "$(dirname "$0")/.." && pwd)
[ -f "$OL/flow.tcl" ] || { echo "$OL has no flow.tcl"; exit 1; }

# geometry files, all from one set of numbers
python3 "$KIT/openlane/gen_openlane_files.py" --pe-area "$PE_AREA" --out "$KIT/openlane/designs" "$@"
# the hardened core (rows + OpenRAM macros) - same row size, its own floorplan
CORE_ARGS=()
while [ $# -gt 0 ]; do
    case "$1" in --util|--gap|--name-style) CORE_ARGS+=("$1" "$2"); shift 2 ;; *) shift ;; esac
done
# CORE_GEN_ARGS (env): core-only floorplan options, e.g. "--b-gap-x spread --a-gap-x 120"
# shellcheck disable=SC2086
python3 "$KIT/openlane/gen_core_files.py" --pe-area "$PE_AREA" --out "$KIT/openlane/designs" \
    ${CORE_ARGS[@]+"${CORE_ARGS[@]}"} ${CORE_GEN_ARGS:-} > "$KIT/openlane/designs/gemm_core/floorplan.txt" \
    || { cat "$KIT/openlane/designs/gemm_core/floorplan.txt"; exit 1; }

# the AXI shell measurement run (rtl_asic/axi without the core)
python3 "$KIT/openlane/gen_axi_files.py" --out "$KIT/openlane/designs"

cp "$KIT/openlane/designs/gemm_common.tcl" "$OL/designs/"
for d in gemm_pe gemm_row gemm_array gemm_core gemm_axi_shell; do
    mkdir -p "$OL/designs/$d/src"
    cp "$KIT"/openlane/designs/$d/* "$OL/designs/$d/" 2>/dev/null || true
    cp "$KIT"/rtl_asic/*.v "$KIT"/rtl_asic/*.vh "$OL/designs/$d/src/"
done
# AXI wrapper sources go flat into src/ next to the rest (no name clashes:
# GEMM_top.v, GemmAxiShell.v, AxiLiteControlRegs.v, AxisSkidBuffer.v)
cp "$KIT"/rtl_asic/axi/*.v "$OL/designs/gemm_axi_shell/src/"
echo "installed gemm_pe, gemm_row, gemm_array, gemm_core, gemm_axi_shell into $OL/designs"
