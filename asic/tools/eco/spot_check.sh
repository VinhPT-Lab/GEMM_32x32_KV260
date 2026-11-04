#!/bin/bash
# Magic drc(full) of fixed windows of a run's final GDS (full views of the SRAM
# and row macros), reusing the KLayout clip and Magic scripts of
# tools/magic_macro_check.sh. Every error in a window is listed, nothing waived.
# usage: spot_check.sh <run dir> <out.rpt> "<name> x0 y0 x1 y1" ...   (um)
set -uo pipefail
source "$(dirname "$0")/env.sh"
T=$(cd "$(dirname "$0")/.." && pwd)    # tools/: magic_macro_check_clip.py, magic_macro_check.tcl
RUN=$1; OUT=$2; shift 2
DEF=$(ls "$RUN"/results/final/def/*.def | head -1)
TOP=$(sed -n 's/^DESIGN \(\S*\) ;/\1/p' "$DEF" | head -1)
GDS=$RUN/results/final/gds/$TOP.gds
WORK=$RUN/tmp/signoff/spot_check; rm -rf "$WORK"; mkdir -p "$WORK"
python3 - "$WORK" "$@" <<'PY'
import json, sys
work = sys.argv[1]; wins = []
for i, s in enumerate(sys.argv[2:]):
    t = s.split(); wins.append({"n": i, "name": t[0], "box": [float(v) for v in t[1:5]]})
json.dump({"windows": wins, "markers": []}, open(work + "/windows.json", "w"), indent=1)
with open(work + "/windows.tcl", "w") as f:
    f.write("set gemm_windows {\n")
    for w in wins: f.write("  %d {%.3f %.3f %.3f %.3f}\n" % ((w["n"],) + tuple(w["box"])))
    f.write("}\n")
PY
RUN=$(realpath "$RUN")
dk() { docker run --rm "${DOCKER_COMMON[@]}" -v "$RUN:$RUN" -v "$T:$T" \
  -e PDK=sky130A -e MAGTYPE=mag -e GEMM_WORK="$WORK" -e GEMM_GDS="$GDS" -e GEMM_TOP="$TOP" \
  "$OL_IMAGE" "$@"; }
dk klayout -b -r $T/magic_macro_check_clip.py > "$WORK/klayout.log" 2>&1
[ -s "$WORK/clips.gds" ] || { echo "no clips.gds (see $WORK/klayout.log)"; exit 1; }
dk sh -c "magic -noconsole -dnull -rcfile $PDK_ROOT/sky130A/libs.tech/magic/sky130A.magicrc $T/magic_macro_check.tcl < /dev/null" > "$WORK/magic.log" 2>&1
python3 - "$WORK" "$OUT" <<'PY'
import json, re, sys
work, out = sys.argv[1:3]
wins = json.load(open(work + "/windows.json"))["windows"]
errs = {w["n"]: [] for w in wins}; done = set()
for l in open(work + "/magic.log"):
    m = re.match(r'GEMM_ERR (\d+) \{(.*)\} (\S+) (\S+) (\S+) (\S+)', l)
    if m: errs[int(m.group(1))].append((m.group(2),) + tuple(float(v) for v in m.group(3, 4, 5, 6)))
    m = re.match(r'GEMM_DONE (\d+)', l)
    if m: done.add(int(m.group(1)))
L = ["spot_check: Magic drc(full) on fixed windows of the final GDS (full macro views), nothing waived"]
for w in wins:
    e = errs[w["n"]]
    L.append(f"window {w['name']} {w['box']}: {'checked' if w['n'] in done else 'NOT CHECKED'}, {len(e)} error box(es)")
    for x in e[:50]: L.append(f"   {x[0]}  ({x[1]:.3f}, {x[2]:.3f}) - ({x[3]:.3f}, {x[4]:.3f})")
open(out, "w").write("\n".join(L) + "\n"); print("\n".join(L))
PY
