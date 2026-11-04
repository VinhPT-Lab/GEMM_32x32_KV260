#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# magic_macro_check.sh <run> [--skip <rule> ...]
#
# Magic DRC of the core runs on the abstract views of the macros (OpenRAM, row
# macros): their OBS rectangles count as solid metal, so routing that lands on
# a macro pin or passes by its edge can show wide-metal spacing errors
# (met4.5b, met2.3b, ...) that the real layout does not have (core_v6r: all
# 57 metal markers). This script rechecks those markers on the full layout:
#   - markers of reports/signoff/drc.rpt within 2 um of a macro bbox
#     (COMPONENTS of results/final/def, sizes from tmp/merged.nom.lef),
#   - grouped into 10x10 um windows, clipped from results/final/gds/<design>.gds
#     in one KLayout read,
#   - Magic drc(full) on every window; errors within +-0.5 um of a marker
#     count, errors touching the clip edge do not.
# Never waived: markers not next to a macro, and routing over a macro itself
# ("Can't overlap those layers", or a marker more than 5 um inside a macro) -
# a wire merged into macro metal is no DRC error on the full layout, and the
# OpenRAM bitcells break generic rules on their own (core_v7r: net3191 on met2
# across an SRAM). --skip <rule> leaves a rule out (its tag, e.g. nwell.4). Writes reports/signoff/magic_macro_check.rpt;
# exit 0 only if every non-skipped marker is an abstract artefact.
# Runs KLayout and Magic in the OpenLane image (OL_IMAGE); a few GB of RAM for
# the GDS read, so not next to a detailed route.
# ---------------------------------------------------------------------------
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
IMG=${OL_IMAGE:-ghcr.io/the-openroad-project/openlane:ff5509f65b17bfa4068d5336495ab1718987ff69-amd64}
# RAM limit as openlane/run_flow.sh (DOCKER_MEMORY / DOCKER_SWAP, empty = none)
MEM=()
[ -n "${DOCKER_MEMORY-10g}" ] && MEM+=(--memory="${DOCKER_MEMORY-10g}")
[ -n "${DOCKER_SWAP-40g}" ] && MEM+=(--memory-swap="${DOCKER_SWAP-40g}")
PDK_ROOT=${PDK_ROOT:-$HOME/.ciel}

[ $# -ge 1 ] || { sed -n '3,24p' "$0"; exit 2; }
RUN=$(cd "$1" && pwd) || exit 2
shift
SKIP=()
while [ $# -gt 0 ]; do
    case $1 in
        --skip) SKIP+=("$2"); shift 2 ;;
        *) echo "unknown option $1"; exit 2 ;;
    esac
done

RPT=$RUN/reports/signoff/drc.rpt
DEF=$(ls "$RUN"/results/final/def/*.def 2>/dev/null | head -1)
LEF=$RUN/tmp/merged.nom.lef
DESIGN=$(sed -n 's/^DESIGN \(\S*\) ;/\1/p' "$DEF" 2>/dev/null | head -1)
GDS=$RUN/results/final/gds/$DESIGN.gds
for f in "$RPT" "$DEF" "$LEF" "$GDS"; do
    [ -s "$f" ] || { echo "missing: $f"; exit 2; }
done
WORK=$RUN/tmp/signoff/magic_macro_check
OUT=$RUN/reports/signoff/magic_macro_check.rpt
rm -rf "$WORK"; mkdir -p "$WORK"

docker_ol() {
    docker run --rm "${MEM[@]}" -v "$HOME:$HOME" -v "$PDK_ROOT:$PDK_ROOT" -e PDK_ROOT="$PDK_ROOT" -e PDK=sky130A \
        -e MAGTYPE=mag -e GEMM_WORK="$WORK" -e GEMM_GDS="$GDS" -e GEMM_TOP="$DESIGN" \
        --user "$(id -u):$(id -g)" "$IMG" "$@"
}

echo "== magic_macro_check: $RUN"
python3 "$HERE/magic_macro_check.py" prep "$RPT" "$DEF" "$LEF" "$WORK" "${SKIP[@]}" || exit 1
if grep -q '^  [0-9]' "$WORK/windows.tcl"; then
    docker_ol klayout -b -r "$HERE/magic_macro_check_clip.py" 2>&1 | tee "$WORK/klayout.log" | grep -E '^  ' || true
    [ -s "$WORK/clips.gds" ] || { echo "KLayout wrote no clips.gds - see $WORK/klayout.log"; exit 1; }
    docker_ol sh -c "magic -noconsole -dnull -rcfile $PDK_ROOT/sky130A/libs.tech/magic/sky130A.magicrc $HERE/magic_macro_check.tcl < /dev/null" \
        > "$WORK/magic.log" 2>&1
    echo "  Magic: $(grep -c '^GEMM_DONE' "$WORK/magic.log") windows checked"
else
    : > "$WORK/magic.log"
fi
python3 "$HERE/magic_macro_check.py" report "$WORK" "$WORK/magic.log" "$OUT"
rc=$?
echo "  written: $OUT"
exit $rc
