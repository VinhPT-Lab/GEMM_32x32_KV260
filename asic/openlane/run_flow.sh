#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# run_flow.sh - GEMM ASIC flow on OpenLane 1.0.2, bottom-up, one checked stage at a time.
#
#   openlane/run_flow.sh sim        ASIC RTL vs FPGA RTL (original testbench, cycle-exact)
#   openlane/run_flow.sh pe         one PE (its area sizes the row)
#   openlane/run_flow.sh row        32-PE row macro (+ netlist vs RTL check)
#   openlane/run_flow.sh array      FeatureSkew + 32 row macros + OutputDeskew
#   openlane/run_flow.sh core-sim   core RTL with the OpenRAM models, 3 matrix shapes
#   openlane/run_flow.sh core-pre   core lint + synthesis + floorplan (~1 h)
#   openlane/run_flow.sh core       core GemmAccelerator: 32 rows + 80 SRAM, full run (~7 h)
#   openlane/run_flow.sh core-gls   original testbench on the final core netlist, 3 shapes
#   openlane/run_flow.sh core-status   progress of the running / last core run
#   openlane/run_flow.sh core-check    judge an existing core run again (no OpenLane)
#   openlane/run_flow.sh core-route    route + signoff again from the post-CTS layout of a run
#   openlane/run_flow.sh axi-sim    AXI IP (rtl_asic/axi): slice + shell tests, original testbench, all variants
#   openlane/run_flow.sh axi-shell  harden the AXI shell alone (thin, reg, lean, lean_cg) + overhead table
#   openlane/run_flow.sh axi-gls    original testbench on GEMM_top (lean + clock gating) around the final core netlist
#   openlane/run_flow.sh ip-shell   AXI macro of the complete IP (lean + clock gating, met1-met4)
#   openlane/run_flow.sh ip-pre     complete IP GEMM_top: synthesis .. global route, floorplan checks
#   openlane/run_flow.sh ip         complete IP: full run (~10 h), GDS of the whole IP
#   openlane/run_flow.sh ip-route   route + signoff again from the post-CTS layout of an IP run
#   openlane/run_flow.sh ip-status  progress of the running / last IP run
#   openlane/run_flow.sh ip-check   DRC (+ flags around macros on the full GDS), LVS, antenna, corners, power
#   openlane/run_flow.sh ip-gls     original testbench on the final IP netlist (rows + AXI macro gate-level), 3 shapes
#   openlane/run_flow.sh status     stages passed so far (openlane/LOG.md)
#   Diagnostics: core-triage, core-probe, core-precheck, array-check (see the functions below).
#
# Each stage starts only after the one before it passed, prints STAGE <x> PASS|FAIL
# and appends a line (with peak RAM) to openlane/LOG.md.
#
# Environment [default]:
#   OL          OpenLane checkout                        [$HOME/OpenLane]
#   REPO        original GEMM_32x32_KV260 repo           [../GEMM_32x32_KV260-main]
#   TAG         core: run name [core_v11]; core-gls / core-check / core-status: run to use
#   FROM        core-route: run to continue from          [last core run]
#   MIN_DISK_GB core / core-route stop below this free disk [40]
#   DRT_SEEDS   detailed-router seeds tried in turn       [core: "42 7 23"]
#   ANT_ECO     antenna ECO rounds after routing, 0 = off [3]
#   ROW         core-gls: row model, rtl or gl (gate netlist of the row run) [gl]
#   CORE_RUN    axi-shell / axi-gls: core run to compare with / simulate [last core run that passed]
#   IP_TAG      ip: run name [ip_v1]; ip-route / ip-check / ip-gls / ip-status: run to use [last ip run]
#   IP_CLOCK_PERIOD ip / ip-route: CLOCK_PERIOD of gemm_ip in ns [OpenLane default 10]; ip-route
#               rebuilds the post-CTS SDC at it (ip_post_cts.sdc). The timing gate checks
#               GEMM_GATE_PERIOD [10] - set both.
#   IP_SHELL_TAG ip-shell: run name of the AXI macro [ip_shell]
#   IP_CORE_TAG ip-shell / ip-pre: core run whose floorplan the IP reuses [core_v11]
#   AUTO_COMMIT=1  git commit + tag the kit on every PASS
# ---------------------------------------------------------------------------
set -uo pipefail

KIT=$(cd "$(dirname "$0")/.." && pwd)
OL=${OL:-$HOME/OpenLane}
# RAM limit of every OpenLane container: OpenLane's Makefile turns DOCKER_MEMORY /
# DOCKER_SWAP into docker run --memory / --memory-swap (tools/*.sh read the same
# two). 10 GB of RAM, the rest goes to swap (40 GB RAM + swap in all), so the
# desktop keeps ~5 GB (at 11 GB ip_v3 left it 0.5 GB) and a run out of memory
# is killed instead of hanging the machine. DOCKER_MEMORY= DOCKER_SWAP= (empty)
# runs without a limit.
export DOCKER_MEMORY=${DOCKER_MEMORY-10g} DOCKER_SWAP=${DOCKER_SWAP-40g}
REPO=${REPO:-$KIT/../GEMM_32x32_KV260-main}
HERE=$KIT/openlane
LOG=$HERE/LOG.md
STATE=$HERE/state
STAMP=$(date +%Y%m%d-%H%M%S)
mkdir -p "$STATE" "$HERE/logs"
[ -f "$LOG" ] || printf "# OpenLane flow log\n\n| time | stage | result | peak RAM (MB) | note |\n|---|---|---|---|---|\n" > "$LOG"

FAILS=0; NOTE=""; PEAK="-"; MEMPEAK=""; MEMW_PID=""
CORE_GEN_DEFAULT="--layout v3 --b-wide --b-gap-y 200 --strip 1000 --a-gap-x 200"   # core floorplan v5/v6 (see gen_core_files.py)
trap '[ -n "${MEMW_PID:-}" ] && kill "$MEMW_PID" 2>/dev/null' EXIT
say()  { printf "\n\033[1m== %s\033[0m\n" "$*"; }
pass() { printf "  \033[32mPASS\033[0m %s\n" "$*"; }
fail() { printf "  \033[31mFAIL\033[0m %s\n" "$*"; FAILS=$((FAILS+1)); }

need() {   # need <stage>: refuse to run before <stage> passed
    grep -q "| $1 | PASS |" "$LOG" || { echo "Stage '$1' has not passed yet - run: openlane/run_flow.sh $1"; exit 1; }
}

finish() {   # finish <stage>
    local st=$1 result=PASS
    [ $FAILS -gt 0 ] && result=FAIL
    echo "| $STAMP | $st | $result | $PEAK | $NOTE |" >> "$LOG"
    if [ $result = PASS ] && [ "${AUTO_COMMIT:-0}" = 1 ] && git -C "$KIT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        git -C "$KIT" add -A rtl_asic sim openlane tools 2>/dev/null
        git -C "$KIT" commit -qm "OpenLane stage $st PASS" >/dev/null 2>&1
        git -C "$KIT" tag "ol-$st-pass-$STAMP" 2>/dev/null && echo "  git tag ol-$st-pass-$STAMP"
    fi
    if [ $result = PASS ]; then printf "\n\033[32mSTAGE %s PASS\033[0m\n" "$st"
    else printf "\n\033[31mSTAGE %s FAIL\033[0m (%d problems)\n" "$st" "$FAILS"; exit 1; fi
}

disk_free_gb() { df -BG --output=avail "$OL" 2>/dev/null | tail -1 | tr -dc '0-9'; }

need_disk() {   # need_disk <GB>: stop before OpenLane starts when the disk of $OL has less free
    # (core_v7r died at 13:01 03/10 with the disk full: OpenROAD could not write a DEF)
    local want=$1 have
    have=$(disk_free_gb)
    [ -n "$have" ] || { echo "  (free disk space of $OL unknown - not checked)"; return 0; }
    if [ "$have" -lt "$want" ]; then
        echo "  disk: only $have GB free on the disk of $OL, this stage needs at least $want GB"
        echo "  (a core route + signoff writes ~25 GB). Remove old runs/<tag>/tmp and results first,"
        echo "  or set MIN_DISK_GB lower if you know it fits."
        exit 1
    fi
    echo "  disk free    : $have GB (this stage needs $want)"
}

mem_watch_start() {   # mem_watch_start <file>: every 10 s, biggest EDA process RSS + free RAM + swap + free disk (GB)
    MEMW_FILE=$1; : > "$MEMW_FILE"
    (
        while :; do
            p=$(ps -eo rss=,comm= 2>/dev/null | awk '$2 ~ /^(openroad|magic|netgen|klayout|yosys|cvc)/ && $1 > m { m = $1; c = $2 }
                                                 END { printf "%d %s", m / 1024, (c == "" ? "-" : c) }')
            a=$(awk '/^MemAvailable:/{print int($2/1024)}' /proc/meminfo)
            s=$(awk '/^SwapTotal:/{t=$2} /^SwapFree:/{f=$2} END{print int((t-f)/1024)}' /proc/meminfo)
            echo "$(date +%H:%M:%S) $p $a $s $(disk_free_gb)" >> "$MEMW_FILE"
            sleep 10
        done
    ) &
    MEMW_PID=$!
}

mem_watch_stop() {   # stop the sampler, print the summary, MEMPEAK = peak RSS (MB)
    [ -n "${MEMW_PID:-}" ] && { kill "$MEMW_PID" 2>/dev/null; wait "$MEMW_PID" 2>/dev/null; }
    MEMW_PID=""
    [ -s "${MEMW_FILE:-}" ] || return 0
    local pk pc ma ms
    read -r pk pc ma ms <<< "$(awk '{ if ($2 > p) { p = $2; c = $3 } if (m == "" || $4 < m) m = $4; if ($5 > s) s = $5 }
                                    END { print p + 0, (c == "" ? "-" : c), m + 0, s + 0 }' "$MEMW_FILE")"
    MEMPEAK=$pk
    echo "  memory: peak $pk MB ($pc), lowest free RAM $ma MB, most swap in use $ms MB (${MEMW_FILE#"$KIT"/})"
}

ol_run() {   # ol_run <design> <tag>: one full OpenLane run, output teed to a log
    local design=$1 tag=$2
    local log=$HERE/logs/${design}_${tag}_$STAMP.log
    [ -f "$OL/flow.tcl" ] || { echo "OpenLane not found at $OL (set OL=...)"; exit 1; }
    echo "  OpenLane: $design (tag $tag) - log: ${log#"$KIT"/}"
    mem_watch_start "$HERE/logs/mem_${design}_${tag}_$STAMP.txt"
    make -C "$OL" quick_run QUICK_RUN_DESIGN="$design -tag $tag -overwrite" 2>&1 | tee "$log"
    local rc=${PIPESTATUS[0]}
    mem_watch_stop
    [ "$rc" -eq 0 ] || fail "OpenLane run $design/$tag stopped (see the log above)"
    RUNDIR=$OL/designs/$design/runs/$tag
}

ol_full() {   # ol_full <tag>: the whole gemm_core flow through core_full.tcl (interactive mode)
    local tag=$1
    local log=$HERE/logs/gemm_core_${tag}_$STAMP.log
    [ -f "$OL/flow.tcl" ] || { echo "OpenLane not found at $OL (set OL=...)"; exit 1; }
    cat > "$OL/designs/gemm_core/full_params.tcl" <<EOF
# written by run_flow.sh $STAMP for designs/gemm_core/core_full.tcl
set GEMM_NEW_TAG $tag
EOF
    echo "  OpenLane (core_full.tcl): gemm_core (tag $tag) - log: ${log#"$KIT"/}"
    mem_watch_start "$HERE/logs/mem_gemm_core_${tag}_$STAMP.txt"
    make -C "$OL" quick_run QUICK_RUN_DESIGN="gemm_core -it -file designs/gemm_core/core_full.tcl" 2>&1 | tee "$log"
    local rc=${PIPESTATUS[0]}
    mem_watch_stop
    [ "$rc" -eq 0 ] || fail "OpenLane run gemm_core/$tag stopped (see the log above)"
    RUNDIR=$OL/designs/gemm_core/runs/$tag
}

# routing overrides shared by core / core-route / core-probe, appended to $ovr
route_overrides() {
    [ -n "${GRT_ADJ:-}" ] && ovr+=$'\n'"set ::env(GRT_LAYER_ADJUSTMENTS) \"$GRT_ADJ\""
    # GRT_ITERS=N: congestion iterations of the global route, for core and core-route
    # (FastRoute here has crashed on very long detours in late iterations - try a probe first)
    [ -n "${GRT_ITERS:-}" ] && ovr+=$'\n'"set ::env(GRT_OVERFLOW_ITERS) $GRT_ITERS"
    # ANT_MARGIN=N: GRT_ANT_MARGIN (%) of repair_antennas in the global route, for core and core-route
    # (v9 post-CTS, met1 0.5: margin 50 -> same overflow 46, 66k diodes instead of 39k)
    [ -n "${ANT_MARGIN:-}" ] && ovr+=$'\n'"set ::env(GRT_ANT_MARGIN) $ANT_MARGIN"
    [ "${MET5_OVER_SRAM:-0}" = 1 ] && ovr+=$'\n'"catch { unset ::env(GRT_OBS) }"
    [ "${1:-}" = probe ] && return 0
    ovr+=$'\n'"set ::env(GEMM_ANT_ECO_ITERS) ${ANT_ECO:-3}"
    return 0
}

check_run() {   # check_run <run dir> [--waive-io-timing]: signoff metrics + peak RAM
    if python3 "$HERE/check_openlane_run.py" ${2:-} "$1" | tee "$STATE/last_check.txt"; then
        pass "signoff checks ${1#"$OL"/}"
    else fail "signoff checks ${1#"$OL"/}"; fi
    PEAK=$(awk -F'= ' '/Peak_Memory_Usage_MB/{split($2,a," "); print a[1]}' "$STATE/last_check.txt")
    # OpenLane writes -1 when it could not measure; the host-side sampler knows
    case "$PEAK" in ""|-1|-1.0) PEAK=${MEMPEAK:-"-"} ;; esac
}

# =========================================================================
st_sim() {
    say "sim: original RTL vs ASIC RTL"
    local out=$HERE/logs/sim_$STAMP; mkdir -p "$out"
    if "$KIT/sim/run_equiv.sh" "$REPO/rtl" > "$out/equiv.log" 2>&1; then
        pass "equivalence, GEMM_DP_RESET=1 and 0: $(grep -c 'EQUIVALENCE PASS' "$out/equiv.log")/2 PASS"
    else fail "equivalence (see ${out#"$KIT"/}/equiv.log)"; fi
    local n; n=$(awk '$1=="`define" && $2=="GEMM_N"{print $3}' "$KIT/rtl_asic/gemm_asic_cfg.vh")
    if [ "$n" = 32 ]; then
        "$KIT/sim/run_system.sh" orig "$REPO" > "$out/sys_orig.log" 2>&1 && pass "original RTL: OVERALL PASS" \
            || fail "original RTL failed its own testbench"
        "$KIT/sim/run_system.sh" asic "$REPO" > "$out/sys_asic.log" 2>&1 && pass "ASIC RTL: OVERALL PASS" \
            || fail "ASIC RTL failed the original testbench"
        grep -E "RESULT_VALID_FIRST|RESULT_ACCEPT" "$KIT/sim/build_system_orig/system.log" > "$out/cycles_orig.txt" 2>/dev/null
        grep -E "RESULT_VALID_FIRST|RESULT_ACCEPT" "$KIT/sim/build_system_asic/system.log" > "$out/cycles_asic.txt" 2>/dev/null
        if [ -s "$out/cycles_orig.txt" ] && diff -q "$out/cycles_orig.txt" "$out/cycles_asic.txt" >/dev/null; then
            pass "same cycle for all $(wc -l < "$out/cycles_asic.txt") result events as the FPGA RTL"
        else fail "result cycles differ from the FPGA RTL (diff cycles_*.txt in ${out#"$KIT"/})"; fi
    else
        fail "GEMM_N=$n in gemm_asic_cfg.vh; the OpenLane configs are for 32 - set it back to 32"
    fi
    NOTE="logs in ${out#"$KIT"/}"
    finish sim
}

st_pe() {
    need sim
    say "pe: one ProcessingElement"
    ol_patches || { fail "patch OpenLane scripts"; finish pe; }
    "$HERE/install_into_openlane.sh" "$OL" >/dev/null || { fail "install into $OL"; finish pe; }
    ol_run gemm_pe pe_v1
    check_run "$RUNDIR"
    local area
    area=$(grep -h "Chip area" "$RUNDIR"/reports/synthesis/*.stat.rpt 2>/dev/null | tail -1 | awk '{print $NF}')
    if [ -n "$area" ]; then
        echo "$area" > "$STATE/pe_area.txt"
        pass "PE cell area $area um^2 (saved; row and array are sized from it)"
        NOTE="PE area $area um^2"
    else fail "could not read 'Chip area' from $RUNDIR/reports/synthesis/*.stat.rpt"; fi
    finish pe
}

st_row() {
    need pe
    say "row: 32-PE macro"
    local area; area=$(cat "$STATE/pe_area.txt")
    ol_patches || { fail "patch OpenLane scripts"; finish row; }
    # shellcheck disable=SC2086
    "$HERE/install_into_openlane.sh" "$OL" --pe-area "$area" ${GEN_ARGS:-} | tee "$STATE/geometry.txt" \
        || { fail "install/geometry"; finish row; }
    ol_run gemm_row row_v1
    check_run "$RUNDIR"
    local lef=$RUNDIR/results/final/lef/ProcessingElementRow.lef
    if [ -s "$lef" ]; then
        python3 "$KIT/tools/check_row_lef.py" "$lef" 32 8 5 && pass "row LEF: power pins + 928 top/bottom pins aligned" \
            || fail "row LEF checks"
    else fail "no $lef"; fi
    # LVS only compares layout with the netlist; this compares the netlist with the RTL
    if "$KIT/sim/row_equiv.sh" "$RUNDIR/results/final/verilog/gl/ProcessingElementRow.nl.v" > "$HERE/logs/row_equiv_$STAMP.log" 2>&1; then
        pass "row netlist = RTL (random stimulus, $(grep -o 'cycles=[0-9]*' "$HERE/logs/row_equiv_$STAMP.log"))"
    else fail "row netlist differs from the RTL:"; tail -n 6 "$HERE/logs/row_equiv_$STAMP.log" | sed 's/^/    /'; fi
    NOTE="$(head -1 "$STATE/geometry.txt")"
    finish row
}

st_array() {
    need row
    say "array: FeatureSkew + 32 row macros + OutputDeskew"
    # I/O delays for array.sdc from the clock latency the previous run measured
    local prev=$OL/designs/gemm_array/runs/array_v1
    if [ -d "$prev/reports/signoff" ]; then
        python3 "$KIT/tools/clock_latency.py" "$prev" "$HERE/designs/gemm_array/clk_latency.tcl" \
            || echo "  (no clock latency from the previous run - array.sdc falls back to base.sdc values)"
    fi
    ol_patches || { fail "patch OpenLane scripts"; finish array; }
    # re-copy RTL + configs (same geometry: same PE area and GEN_ARGS as the row)
    # shellcheck disable=SC2086
    "$HERE/install_into_openlane.sh" "$OL" --pe-area "$(cat "$STATE/pe_area.txt")" ${GEN_ARGS:-} >/dev/null \
        || { fail "install into $OL"; finish array; }
    ol_run gemm_array array_v1
    array_verdict
}

array_verdict() {   # judge $RUNDIR as the array stage
    # OpenLane itself exits non-zero at its final timing gate on the I/O paths,
    # so the verdict starts from zero and judges the run on its own
    FAILS=0
    local placed
    placed=$(grep -rhoE "Successfully placed [0-9]+ instances" "$RUNDIR/logs" 2>/dev/null | tail -1 | awk '{print $3}')
    if [ "$placed" = 32 ]; then pass "32 row macros placed from macro.cfg"
    else
        fail "macro placement placed '${placed:-0}' rows, expected 32"
        echo "  hint: if the floorplan log says 'Macros not found', regenerate with the other name style:"
        echo "        python3 openlane/gen_openlane_files.py --pe-area $(cat "$STATE/pe_area.txt") --name-style plain --out $OL/designs"
    fi
    # internal timing only (see check_openlane_run.py --waive-io-timing)
    check_run "$RUNDIR" --waive-io-timing
    NOTE="GDS: ${RUNDIR#"$OL"/}/results/final/gds/ProcessingElementArray.gds (I/O timing waived)"
    finish array
}

# =========================================================================
# level 3: the hardened GEMM core (GemmAccelerator)
st_core_sim() {
    need sim
    say "core-sim: GemmAccelerator RTL (W1024/F512/O512) - behavioural vs OpenRAM macro models vs FPGA RTL"
    local out=$HERE/logs/core_sim_$STAMP; mkdir -p "$out"
    # shape "" = the testbench's 64x64x64 (2 K blocks, 2 N blocks); the other
    # two are shapes the FPGA software would send and that reach the SECOND
    # bank of the 1024-word memories, which 64x64x64 never touches:
    #   8,32,544  : 17 N blocks -> feeder weight tile addr up to 543, input weight 544 words
    #   16,992,32 : 31 K blocks -> input weight 992 words, longest accumulation
    local shape v tag
    for shape in "" "8,32,544" "16,992,32"; do
        tag=${shape:+_M$(echo "$shape" | awk -F, '{print $1"K"$2"N"$3}')}
        local vars="orig asic-sram"; [ -z "$shape" ] && vars="orig asic asic-sram"
        for v in $vars; do
            if TB_SHAPE="$shape" "$KIT/sim/run_system.sh" "$v" "$REPO" > "$out/sys_$v$tag.log" 2>&1; then
                pass "$v${shape:+ ($shape)}: OVERALL PASS"
            else fail "$v${shape:+ ($shape)} failed the testbench (see ${out#"$KIT"/}/sys_$v$tag.log)"; fi
            grep -E "RESULT_VALID_FIRST|RESULT_ACCEPT" "$KIT/sim/build_system_$v$tag/system.log" > "$out/cycles_$v$tag.txt" 2>/dev/null
        done
        [ -z "$shape" ] && grep -E "SRAM model|same-address|^ +[0-9]+ +u_" "$out/sys_asic-sram.log" | sed "s/^/  /"
        for v in $vars; do
            [ "$v" = orig ] && continue
            if [ -s "$out/cycles_orig$tag.txt" ] && diff -q "$out/cycles_orig$tag.txt" "$out/cycles_$v$tag.txt" >/dev/null; then
                pass "$v${shape:+ ($shape)}: same cycle for all $(wc -l < "$out/cycles_$v$tag.txt") result events as the FPGA RTL"
            else fail "$v${shape:+ ($shape)}: result cycles differ from the FPGA RTL (diff ${out#"$KIT"/}/cycles_*$tag.txt)"; fi
        done
    done
    NOTE="logs in ${out#"$KIT"/}"
    finish core-sim
}

gpl_hook() {   # let a design pass extra global_placement options (GPL_EXTRA_ARGS)
    local f=$OL/scripts/openroad/gpl.tcl
    [ -f "$f" ] || { echo "  note: $f not found - GPL_EXTRA_ARGS will be ignored"; return 0; }
    grep -q "GPL_EXTRA_ARGS" "$f" && return 0
    [ -f "$f.orig_gemm" ] || cp "$f" "$f.orig_gemm"
    python3 - "$f" <<'PY' || { echo "  could not add the GPL_EXTRA_ARGS hook to $f"; return 1; }
import sys
p = sys.argv[1]; s = open(p).read()
key = "global_placement {*}$arg_list"
if key not in s:
    sys.exit(1)
hook = ("# gemm_asic_kit: extra options for designs that set GPL_EXTRA_ARGS\n"
        "if { [info exists ::env(GPL_EXTRA_ARGS)] } { lappend arg_list {*}$::env(GPL_EXTRA_ARGS) }\n")
open(p, "w").write(s.replace(key, hook + key, 1))
PY
    echo "  added GPL_EXTRA_ARGS hook to $f (original kept as gpl.tcl.orig_gemm)"
}

antenna_fix() {   # OpenLane 1.0.2 bug in the GRT antenna-repair loop (routing.tcl)
    # When an extra antenna iteration REDUCES the violations, routing.tcl does
    #   set minimum_antennae [groute_antenna_extract -from_log [groute_antenna_extract -from_log $log]]
    # i.e. it opens a file named after the violation count and the step dies
    # ("couldn't read file "3""). The intended value is simply $antennae.
    local f=$OL/scripts/tcl_commands/routing.tcl
    [ -f "$f" ] || return 0
    grep -q 'groute_antenna_extract -from_log \[groute_antenna_extract' "$f" || return 0
    [ -f "$f.orig_gemm" ] || cp "$f" "$f.orig_gemm"
    python3 - "$f" <<'PY' || { echo "  could not patch the antenna loop in $f"; return 1; }
import sys
p = sys.argv[1]; s = open(p).read()
bad = "set minimum_antennae [groute_antenna_extract -from_log [groute_antenna_extract -from_log $log]]"
if bad not in s:
    sys.exit(1)
open(p, "w").write(s.replace(bad, "set minimum_antennae $antennae  ;# gemm_asic_kit fix", 1))
PY
    echo "  fixed OpenLane antenna-iteration bug in $f (original kept as routing.tcl.orig_gemm)"
}

dpl_hook() {   # let a design run a Tcl script right before every detailed_placement (DPL_PRE_HOOK)
    # common/dpl_cell_pad.tcl is sourced by resizer.tcl, dpl.tcl, cts.tcl and
    # resizer_timing.tcl immediately before they call detailed_placement.
    local f=$OL/scripts/openroad/common/dpl_cell_pad.tcl
    [ -f "$f" ] || { echo "  note: $f not found - DPL_PRE_HOOK will be ignored"; return 0; }
    grep -q "DPL_PRE_HOOK" "$f" && return 0
    [ -f "$f.orig_gemm" ] || cp "$f" "$f.orig_gemm"
    printf '\n# gemm_asic_kit: per-design hook right before detailed_placement\nif { [info exists ::env(DPL_PRE_HOOK)] && [file exists $::env(DPL_PRE_HOOK)] } { source $::env(DPL_PRE_HOOK) }\n' >> "$f" \
        || { echo "  could not add the DPL_PRE_HOOK hook to $f"; return 1; }
    echo "  added DPL_PRE_HOOK hook to $f (original kept as dpl_cell_pad.tcl.orig_gemm)"
}

drt_seed_hook() {   # detailed router seed from DRT_OR_SEED (OpenLane 1.0.2 hard-codes -or_seed 42)
    # Same input + same seed = same result. When detailed routing ends with a
    # violation it cannot clear (core_v6: one met5 short), another seed gives
    # the router another net order and usually clears it.
    local f=$OL/scripts/openroad/droute.tcl
    [ -f "$f" ] || return 0
    grep -q "DRT_OR_SEED" "$f" && return 0
    grep -q -- "-or_seed 42" "$f" || { echo "  note: no '-or_seed 42' in $f - DRT_OR_SEED will be ignored"; return 0; }
    [ -f "$f.orig_gemm" ] || cp "$f" "$f.orig_gemm"
    python3 - "$f" <<'PYX' || { echo "  could not add DRT_OR_SEED to $f"; return 1; }
import sys
p = sys.argv[1]; s = open(p).read()
s = s.replace("-or_seed 42", "-or_seed [expr {[info exists ::env(DRT_OR_SEED)] ? $::env(DRT_OR_SEED) : 42}]", 1)
open(p, "w").write(s)
PYX
    echo "  detailed router seed now settable (DRT_OR_SEED) in $f (original kept as droute.tcl.orig_gemm)"
}

pinswap_fix() {   # repair_timing without pin swapping (resizer_timing.tcl, resizer_routing_timing.tcl)
    # OpenROAD 41a51eaf swapped A_N and B of an and2b_1 in row_v1 (step 17,
    # "RSZ-0043 Swapped pins on 1 instances"): and2b is not commutative, the
    # netlist changed function and LVS cannot see it (layout = wrong netlist).
    local f
    for f in "$OL/scripts/openroad/resizer_timing.tcl" "$OL/scripts/openroad/resizer_routing_timing.tcl"; do
        [ -f "$f" ] || continue
        grep -q -- "-skip_pin_swap" "$f" && continue
        [ -f "$f.orig_gemm" ] || cp "$f" "$f.orig_gemm"
        python3 - "$f" <<'PY' || { echo "  could not add -skip_pin_swap to $f"; return 1; }
import sys
p = sys.argv[1]; s = open(p).read()
key = "repair_timing -setup \\\n"
if key not in s:
    sys.exit(1)
open(p, "w").write(s.replace(key, "repair_timing -setup -skip_pin_swap \\\n"))
PY
        echo "  repair_timing -skip_pin_swap in $f (original kept as ${f##*/}.orig_gemm)"
    done
}

ol_patches() { gpl_hook && antenna_fix && dpl_hook && drt_seed_hook && pinswap_fix; }

core_install() {
    ol_patches || return 1
    local root sram="" lib=""
    for root in "${PDK_ROOT:-}" "$HOME/.volare" "$HOME/.ciel" "$OL/pdks"; do
        [ -n "$root" ] && [ -f "$root/${PDK:-sky130A}/libs.ref/sky130_sram_macros/lef/sky130_sram_2kbyte_1rw1r_32x512_8.lef" ] \
            && { sram=$root/${PDK:-sky130A}/libs.ref/sky130_sram_macros; lib=$root/${PDK:-sky130A}/libs.ref/sky130_fd_sc_hd/lef/sky130_fd_sc_hd.lef; break; }
    done
    if [ -n "$sram" ]; then
        pass "OpenRAM macro views found in $sram"
        # the OpenRAM LEF has no antenna data: config.tcl lists this annotated copy in EXTRA_LEFS
        python3 "$HERE/designs/gemm_core/macro_antenna_lef.py" --in "$sram/lef/sky130_sram_2kbyte_1rw1r_32x512_8.lef" \
            --lib-lef "$lib" --out "$HERE/designs/gemm_core/sram_antenna.lef" \
            || { fail "macro_antenna_lef.py (SRAM LEF with antenna data)"; return 1; }
    else
        echo "  note: OpenRAM macro LEF not found under \$PDK_ROOT, ~/.volare, ~/.ciel, \$OL/pdks;"
        echo "        config.tcl stops with a clear error inside OpenLane if they are really missing"
    fi
    # shellcheck disable=SC2086
    CORE_GEN_ARGS=${CORE_GEN_ARGS:-} "$HERE/install_into_openlane.sh" "$OL" --pe-area "$(cat "$STATE/pe_area.txt")" ${GEN_ARGS:-} >/dev/null \
        || { fail "install into $OL (floorplan checks?)"; return 1; }
    sed 's/^/  /' "$HERE/designs/gemm_core/floorplan.txt"
}

st_core_pre() {
    need array; need core-sim
    say "core-pre: GemmAccelerator lint + synthesis + floorplan"
    core_install || finish core-pre
    local log=$HERE/logs/gemm_core_pre_$STAMP.log
    echo "  OpenLane (interactive preflight) - log: ${log#"$KIT"/}"
    make -C "$OL" quick_run QUICK_RUN_DESIGN="gemm_core -it -file designs/gemm_core/preflight.tcl" 2>&1 | tee "$log"
    local rc=${PIPESTATUS[0]}
    RUNDIR=$OL/designs/gemm_core/runs/core_pre
    if [ "$rc" -eq 0 ] && grep -q "GEMM_CORE_PREFLIGHT_DONE" "$log"; then pass "lint, synthesis, floorplan (incl. PDN check) completed"
    else fail "preflight stopped - first error:"; grep -m3 -E "\[ERROR|Error:" "$log" | sed 's/^/    /'; fi
    local net; net=$(ls "$RUNDIR"/results/synthesis/*.v 2>/dev/null | head -1)
    if [ -n "$net" ]; then
        local ns nr nm
        ns=$(grep -cE "^\s*sky130_sram_2kbyte_1rw1r_32x512_8\s" "$net")
        nr=$(grep -cE "^\s*ProcessingElementRow\s" "$net")
        [ "$ns" = 80 ] && pass "netlist: 80 OpenRAM macros" || fail "netlist has $ns OpenRAM macros, expected 80"
        [ "$nr" = 32 ] && pass "netlist: 32 row macros" || fail "netlist has $nr row macros, expected 32"
        nm=$(grep -hoE "Number of cells:\s+[0-9]+" "$RUNDIR"/reports/synthesis/*.stat.rpt 2>/dev/null | tail -1)
        echo "  synthesis: $nm"
    else fail "no synthesis netlist in $RUNDIR/results/synthesis"; fi
    local placed want
    placed=$(grep -rhoE "Successfully placed [0-9]+ instances" "$RUNDIR/logs" 2>/dev/null | tail -1 | awk '{print $3}')
    want=$(awk '/GEMM_CORE_MACROS/{print $3}' "$HERE/designs/gemm_core/sizes.tcl")
    if [ "${placed:-0}" = "$want" ]; then pass "$want hard macros placed from macro.cfg"
    else
        fail "macro placement placed '${placed:-0}', expected $want"
        echo "  hint: 'Macros not found' -> GEN_ARGS='--name-style plain' openlane/run_flow.sh core-pre"
    fi
    NOTE="preflight run ${RUNDIR#"$OL"/}"
    finish core-pre
}

st_core() {
    need core-pre
    say "core: GemmAccelerator full run (rows + 80 OpenRAM macros) - expect several hours"
    need_disk "${MIN_DISK_GB:-40}"
    local prev; prev=$(core_best_run)
    if [ -d "$prev/reports/signoff" ]; then
        python3 "$KIT/tools/clock_latency.py" "$prev" "$HERE/designs/gemm_core/clk_latency.tcl" \
            || echo "  (no clock latency from the previous core run - using the seed from the array)"
    fi
    local tag=${TAG:-core_v11}
    # floorplan of v5/v6 unless CORE_GEN_ARGS is given (set but empty = layout v1)
    CORE_GEN_ARGS=${CORE_GEN_ARGS-$CORE_GEN_DEFAULT}
    echo "$tag" > "$STATE/core_last_tag.txt"
    rm -f "$HERE/designs/gemm_core/overrides.tcl" "$OL/designs/gemm_core/overrides.tcl"
    # routing guards of route_signoff.tcl (core_full.tcl): router seeds, antenna ECO rounds
    local ovr="# written by run_flow.sh core $STAMP"
    ovr+=$'\n'"set ::env(GEMM_DRT_SEEDS) \"${DRT_SEEDS:-42 7 23}\""
    route_overrides
    printf '%s\n' "$ovr" > "$HERE/designs/gemm_core/overrides.tcl"
    sed 's/^/  overrides: /' "$HERE/designs/gemm_core/overrides.tcl"
    core_install || finish core
    # floorplan options of this run, so core-probe / core-route rebuild the same files
    echo "${CORE_GEN_ARGS:-}" > "$STATE/core_gen_args_$tag.txt"
    [ -n "${CORE_GEN_ARGS:-}" ] && echo "  core floorplan options: $CORE_GEN_ARGS"
    ol_full "$tag"
    # global placement can still diverge (GPL-0307) on this floorplan: retry
    # once without timing-driven placement (the resizer fixes timing later)
    if grep -qs "GPL-0307" "$RUNDIR"/logs/placement/*global*.log; then
        echo "  global placement diverged (GPL-0307) - retrying once with PL_TIME_DRIVEN 0"
        printf '%s\n# after GPL-0307 in the previous attempt\nset ::env(PL_TIME_DRIVEN) 0\n' "$ovr" \
            > "$HERE/designs/gemm_core/overrides.tcl"
        FAILS=0
        core_install || finish core
        ol_full "$tag"
    fi
    rm -f "$HERE/designs/gemm_core/overrides.tcl" "$OL/designs/gemm_core/overrides.tcl"
    # every seed of DRT_SEEDS left violations: route again from the post-CTS
    # layout with three more seeds
    local drc=$RUNDIR/reports/routing/drt.drc
    if [ -s "$drc" ] && grep -q "violation type" "$drc"; then
        echo "  $tag: detailed routing left $(grep -c 'violation type' "$drc") violation(s) with every seed -"
        echo "  routing again from its post-CTS layout with other router seeds (run ${tag}r)"
        FAILS=0
        FROM=$tag TAG=${tag}r FORCE=1 DRT_SEEDS="${DRT_SEEDS_RETRY:-101 211 307}" st_core_route   # ends with core_verdict
        return
    fi
    core_verdict
}

core_last_tag() {   # name of the last core run started by core / core-route
    local t=""
    [ -f "$STATE/core_last_tag.txt" ] && t=$(cat "$STATE/core_last_tag.txt")
    echo "${t:-core_v1}"
}

core_best_run() {   # the core run later stages use: the last one that PASSED, else the last one started
    local r=""
    [ -f "$STATE/core_run.txt" ] && r=$(cat "$STATE/core_run.txt")
    [ -n "$r" ] && [ -d "$r" ] && { echo "$r"; return; }
    echo "$OL/designs/gemm_core/runs/$(core_last_tag)"
}

core_state_var() {   # core_state_var <run dir> <VAR>: value in the run's saved state, as a host path
    local v
    v=$(grep -E "^set ::env\($2\) " "$1/config.tcl" 2>/dev/null | tail -1 | sed -E "s/^set ::env\($2\) //; s/^\"//; s/\"$//")
    echo "${v/#\/openlane\//$OL/}"
}

same_floorplan() {   # same_floorplan <source run>: regenerated floorplan files = the layout that run built?
    local a b
    a=$(core_state_var "$1" DIE_AREA)
    b=$(sed -n 's/^set ::env(DIE_AREA) "\(.*\)"/\1/p' "$HERE/designs/gemm_core/sizes.tcl")
    [ -n "$a" ] || return 0
    if python3 -c 'import sys; a=list(map(float,sys.argv[1].split())); b=list(map(float,sys.argv[2].split())); sys.exit(0 if len(a)==len(b) and all(abs(x-y)<0.01 for x,y in zip(a,b)) else 1)' "$a" "$b"; then
        return 0
    fi
    echo "  the die of ${1##*/} is '$a' but the regenerated floorplan files say '$b':"
    echo "  CORE_GEN_ARGS differ from the run being continued (see openlane/state/core_gen_args_*.txt)"
    return 1
}

write_resume_params() {   # write_resume_params <from tag> <new tag> <route|probe> [iterations]
    cat > "$OL/designs/gemm_core/resume_params.tcl" <<EOF
# written by run_flow.sh $STAMP for designs/gemm_core/resume.tcl
set GEMM_FROM_TAG    $1
set GEMM_NEW_TAG     $2
set GEMM_MODE        $3
set GEMM_PROBE_ITERS ${4:-0}
EOF
}

ol_resume() {   # ol_resume <log>: OpenLane interactive run of resume.tcl (params already written)
    echo "  OpenLane (resume.tcl) - log: ${1#"$KIT"/}"
    mem_watch_start "${1%.log}_mem.txt"
    make -C "$OL" quick_run QUICK_RUN_DESIGN="gemm_core -it -file designs/gemm_core/resume.tcl" 2>&1 | tee "$1"
    local rc=${PIPESTATUS[0]}
    mem_watch_stop
    return "$rc"
}

triage_field() {   # triage_field <triage output file> <stage|signal>
    sed -n "s/^TRIAGE .*$2=\([^ ]*\).*/\1/p" "$1"
}

st_core_status() {   # where the running (or last) core run is - reads files only, safe any time
    local tag=${TAG:-$(core_last_tag)}
    local run=$OL/designs/gemm_core/runs/$tag
    say "core-status: $tag"
    [ -d "$run" ] || { echo "  no run directory ${run#"$OL"/} yet"; return 0; }
    local now first started step
    now=$(date +%s)
    first=$(ls -tr "$run"/logs/synthesis/*.log 2>/dev/null | head -1)
    if [ -n "$first" ]; then
        started=$(stat -c %Y "$first")
        printf "  running for  : %dh%02dm (since the first synthesis log)\n" $(( (now - started) / 3600 )) $(( (now - started) % 3600 / 60 ))
    fi
    step=$(grep -ho "\[STEP [0-9]*\]" "$run"/openlane.log 2>/dev/null | tail -1)
    [ -n "$step" ] && echo "  last step    : $step  $(grep -hE '\[INFO\]: (Running|Starting|Skipping)' "$run"/openlane.log 2>/dev/null | tail -1 | sed 's/.*\[INFO\]: //')"
    grep -qs "flow failed\|\[ERROR\]" "$run"/openlane.log && echo "  !! openlane.log has an error: $(grep -h -m1 '\[ERROR\]' "$run"/openlane.log | cut -c1-150)"
    [ -f "$run/reports/metrics.csv" ] && echo "  flow finished: reports/metrics.csv written - run: openlane/run_flow.sh core-check"
    local last
    last=$(ls -t "$run"/logs/*/*.log 2>/dev/null | head -1)
    if [ -n "$last" ]; then
        printf "  newest log   : %s (%s, updated %ds ago)\n" "${last#"$run"/}" "$(du -h "$last" | cut -f1)" $(( now - $(stat -c %Y "$last") ))
        tail -n 3 "$last" | cut -c1-150 | sed 's/^/      | /'
    fi
    local f
    for f in $(ls -tr "$run"/logs/routing/*.log 2>/dev/null); do
        grep -q "GRT-0096" "$f" || continue
        echo "  global route : ${f##*/}: $(grep -A11 'GRT-0096' "$f" | grep '^Total' | tail -1 | awk '{print "total overflow " $NF ", usage " $4}')"
    done
    f=$(ls -t "$run"/logs/routing/*detailed*.log 2>/dev/null | head -1)
    if [ -n "$f" ]; then
        echo "  detailed rt  : $(grep -hE 'Start .*(optimization iteration|routing)\.' "$f" | tail -1 | sed 's/.*\] //')  $(grep -h 'Number of violations' "$f" | tail -1 | sed 's/.*\] *//')"
    fi
    f=$(ls -t "$HERE"/logs/mem_gemm_core_"$tag"_*.txt "$HERE"/logs/gemm_core_route_"$tag"_*_mem.txt 2>/dev/null | head -1)
    [ -n "$f" ] && [ -s "$f" ] && echo "  memory now   : $(tail -n 1 "$f" | awk '{printf "%s: %s %s MB, free RAM %s MB, swap used %s MB", $1, $3, $2, $4, $5}')"
    local p
    p=$(ps -eo etime=,rss=,comm= 2>/dev/null | awk '$3 ~ /^(openroad|yosys|magic|netgen|klayout)/ {printf "%s (%d MB, %s)  ", $3, $2/1024, $1}')
    echo "  EDA process  : ${p:-none running}"
    echo "  disk free: $(disk_free_gb) GB"
}

st_core_triage() {
    local tag=${TAG:-$(core_last_tag)}
    local run=$OL/designs/gemm_core/runs/$tag
    say "core-triage: where and how $tag stopped"
    local out=$HERE/logs/core_triage_${tag}_$STAMP.txt
    {
        python3 "$KIT/tools/core_triage.py" "$run"
        echo; echo "--- this machine"
        free -m | sed 's/^/  /'
        df -h "$OL" | sed 's/^/  /'
        local k
        k=$(journalctl -k -b --no-pager 2>/dev/null | grep -i -E "out of memory|oom-kill|killed process" | tail -n 3)
        echo "  kernel OOM messages this boot: ${k:-none (or no permission to read the kernel log)}"
        coredumpctl list --no-pager 2>/dev/null | grep -i openroad | tail -n 3 | sed 's/^/  core dump: /'
        # a run that ended with GRT-0119 left its congestion report behind: map it
        local rpt def
        rpt=$(ls -t "$run"/tmp/routing/*congestion*.rpt 2>/dev/null | head -1)
        def=$(core_state_var "$run" CURRENT_DEF)
        [ -f "$def" ] || def=$(ls -t "$run"/tmp/cts/*.def "$run"/results/cts/*.def 2>/dev/null | head -1)
        if [ -s "$rpt" ] && [ -f "$def" ] && [ -f "$run/tmp/merged.nom.lef" ]; then
            echo; echo "--- congestion left by the router (${rpt#"$run"/})"
            python3 "$KIT/tools/core_congestion.py" "$rpt" "$def" "$run/tmp/merged.nom.lef" --nets
        fi
        if [ -f "$def" ] && [ -f "$run/tmp/merged.nom.lef" ]; then
            echo; echo "--- where the standard cells sit (${def#"$OL"/})"
            python3 "$KIT/tools/core_placement.py" "$def" "$run/tmp/merged.nom.lef"
            echo; echo "--- cells in the channels between the row macros"
            python3 "$KIT/tools/core_channels.py" "$def" "$run/tmp/merged.nom.lef"
        fi
        grep -h "keep_rows_clear" "$run"/logs/*/*.log 2>/dev/null | sed 's/^/  /' | tail -n 6
    } 2>&1 | tee "$out"
    echo "  (saved to ${out#"$KIT"/}) - triage finished"
}

st_core_probe() {
    need core-pre
    local from=${FROM:-$(core_last_tag)} iters=${ITERS:-0} tag=core_probe
    local src=$OL/designs/gemm_core/runs/$from run=$OL/designs/gemm_core/runs/core_probe
    say "core-probe: global route only on the post-CTS layout of $from ($iters congestion iterations)"
    need_disk 10
    [ -f "$src/config.tcl" ] || { echo "  no $src/config.tcl - run the core stage first"; exit 1; }
    rm -f "$HERE/designs/gemm_core/overrides.tcl" "$OL/designs/gemm_core/overrides.tcl"
    local ovr="# written by run_flow.sh core-probe $STAMP"
    route_overrides probe
    if [ "$(printf '%s\n' "$ovr" | wc -l)" -gt 1 ]; then
        printf '%s\n' "$ovr" > "$HERE/designs/gemm_core/overrides.tcl"
        sed 's/^/  overrides: /' "$HERE/designs/gemm_core/overrides.tcl"
    fi
    CORE_GEN_ARGS=$(cat "$STATE/core_gen_args_$from.txt" 2>/dev/null) core_install || exit 1
    same_floorplan "$src" || exit 1
    write_resume_params "$from" "$tag" probe "$iters"
    local log=$HERE/logs/gemm_core_probe_$STAMP.log
    ol_resume "$log"
    rm -f "$HERE/designs/gemm_core/overrides.tcl" "$OL/designs/gemm_core/overrides.tcl"
    python3 "$KIT/tools/core_triage.py" "$run" > "$STATE/triage_probe.txt"
    sed -n '/^--- routing resources/,/^--- last/p' "$STATE/triage_probe.txt" | sed '$d'
    if grep -q "GEMM_PROBE_DONE" "$log"; then
        pass "global route finished in the probe (congestion allowed)"
        local def lef rpt
        def=$(core_state_var "$src" CURRENT_DEF)
        [ -f "$def" ] || def=$(ls -t "$src"/tmp/cts/*.def "$src"/results/cts/*.def 2>/dev/null | head -1)
        lef=$run/tmp/merged.nom.lef
        rpt=$run/reports/routing/grt_probe_congestion.rpt
        if [ -f "$rpt" ] && [ -f "$def" ] && [ -f "$lef" ]; then
            python3 "$KIT/tools/core_congestion.py" "$rpt" "$def" "$lef" --nets | tee "$HERE/logs/core_congestion_$STAMP.txt"
        else
            echo "  missing for the map: ${rpt##*/} ${def:-<def>} ${lef##*/}"
        fi
        local guide=$run/tmp/routing/grt_probe.guide
        if [ -f "$guide" ] && [ -f "$def" ] && [ -f "$lef" ]; then
            echo "--- nets the global route left through a macro (macro_cross.py)"
            python3 "$HERE/designs/gemm_core/macro_cross.py" --guide "$guide" --def "$def" --lef "$lef" \
                --grt-obs "$(core_state_var "$run" GRT_OBS)" --report "$run/reports/routing/macro_cross.rpt" \
                | sed -n '1,/^  nets with a guide/p'
        else
            echo "  no probe guide - macro_cross.py skipped"
        fi
        local odb=$run/tmp/routing/grt_probe.odb
        [ -f "$odb" ] && echo "  layout + congestion map: ${odb#"$OL"/} ($(du -h "$odb" | cut -f1); delete when done)"
        NOTE="probe of $from: $(grep -c 'violation type' "$rpt" 2>/dev/null || echo 0) overflowing gcell edges"
    else
        fail "global route crashed even in the probe (see ${log#"$KIT"/})"
        sed -n '/^--- last/,$p' "$STATE/triage_probe.txt"
        NOTE="probe of $from crashed"
    fi
    echo "| $STAMP | core-probe | INFO | ${MEMPEAK:--} | $NOTE |" >> "$LOG"
}

st_core_precheck() {   # early look at later steps on an existing run, no routing
    # antenna check (OpenROAD ARC, as signoff runs it) on the routed layout of
    # FROM, plus the setup/hold of its signoff STA. ~15 min.
    need core-pre
    local from=${FROM:-$(core_last_tag)}
    local tag=${from}_check src=$OL/designs/gemm_core/runs/$from
    say "core-precheck: antenna check + timing of the routed layout of $from (run $tag, no routing)"
    need_disk 10
    [ -f "$src/config.tcl" ] || { echo "  no $src/config.tcl - nothing to check"; exit 1; }
    rm -f "$HERE/designs/gemm_core/overrides.tcl" "$OL/designs/gemm_core/overrides.tcl"
    CORE_GEN_ARGS=$(cat "$STATE/core_gen_args_$from.txt" 2>/dev/null) core_install >/dev/null || exit 1
    write_resume_params "$from" "$tag" check
    local log=$HERE/logs/gemm_core_check_${from}_$STAMP.log
    ol_resume "$log" > /dev/null || true
    local run=$OL/designs/gemm_core/runs/$tag
    echo "--- antenna on the routed layout of $from"
    if grep -q GEMM_CHECK_DONE "$log"; then
        grep -h -E "ANT-000[0-9]|Found [0-9]+ (pin|net)" "$run"/logs/signoff/*arc.log 2>/dev/null | tail -n 4 | sed 's/^/  /'
        local rpt; rpt=$(ls -t "$run"/reports/signoff/*antenna_violators.rpt 2>/dev/null | head -1)
        [ -s "$rpt" ] && { echo "  first violators (${rpt##*/}):"; head -n 12 "$rpt" | sed 's/^/    /'; }
    else
        echo "  the check did not finish - last lines of ${log#"$KIT"/}:"; tail -n 8 "$log" | sed 's/^/    /'
    fi
    echo "--- what signoff of $from already measured (I/O timing waived; -1 / MISSING = step did not run)"
    python3 "$HERE/check_openlane_run.py" --waive-io-timing "$src" 2>&1 \
        | grep -E "tritonRoute|Magic|lvs|antenna|spef|setup|hold|RESULT" | sed 's/^/  /'
    echo "| $STAMP | core-precheck | INFO | ${MEMPEAK:--} | antenna + timing of $from |" >> "$LOG"
}

st_core_route() {
    need core-pre
    local from=${FROM:-$(core_last_tag)}
    local tag=${TAG:-${from}r}
    local src=$OL/designs/gemm_core/runs/$from
    say "core-route: routing + signoff from the post-CTS layout of $from (new run $tag)"
    need_disk "${MIN_DISK_GB:-40}"
    [ -f "$src/config.tcl" ] || { echo "  no $src/config.tcl - nothing to continue from"; exit 1; }
    [ "$from" != "$tag" ] || { echo "  TAG must differ from FROM"; exit 1; }
    python3 "$KIT/tools/core_triage.py" "$src" > "$STATE/triage_$from.txt"
    local stage; stage=$(triage_field "$STATE/triage_$from.txt" stage)
    local ovr="# written by run_flow.sh core-route $STAMP (continuing $from)"
    case "$stage" in
        rsz|dpl|after-dpl)
            echo "  $from died after global routing had finished ($stage): this run skips the"
            echo "  GRT-based repair_design (config.tcl already skips the GRT-based timing repair)"
            ovr+=$'\n''set ::env(GLB_RESIZER_DESIGN_OPTIMIZATIONS) 0' ;;
        grt-overflow|grt-initial|grt-congestion)
            if [ "${GRT_ALLOW:-0}" = 1 ]; then
                echo "  $from died inside global routing ($stage); continuing with GRT_ALLOW=1:"
                echo "  global route may finish with overflow and detailed routing has to clean it up"
            elif [ "${FORCE:-0}" != 1 ]; then
                echo "  $from stopped INSIDE global routing ($stage); the same layout and settings"
                echo "  would stop there again. Look at the congestion first (core-triage / core-probe)."
                echo "  If the overflow left is small: GRT_ALLOW=1 GRT_ITERS=18 openlane/run_flow.sh core-route"
                echo "  lets global route finish with it and detailed routing clean it up."
                exit 1
            fi ;;
        finished)
            if [ -z "${DRT_SEED:-}${DRT_SEEDS:-}${GRT_ADJ:-}${ANT_RPT:-}${ANT_ECO:-}" ] && [ "${FORCE:-0}" != 1 ]; then
                echo "  $from ran to the end. To route it again from its post-CTS layout give what"
                echo "  should change (DRT_SEEDS / GRT_ADJ / ANT_ECO / ANT_RPT) or FORCE=1."
                exit 1
            fi
            echo "  $from ran to the end - routing it again from its post-CTS layout" ;;
        *)
            if [ "${FORCE:-0}" != 1 ]; then
                echo "  cannot tell where $from stopped (triage stage '$stage'); see"
                echo "  openlane/run_flow.sh core-triage. FORCE=1 continues anyway."
                exit 1
            fi ;;
    esac
    # GRT_ALLOW=1: global route may end with overflow (detailed routing fixes it);
    # GRT_ITERS is in route_overrides (FastRoute here crashes on very long
    # detours, which only show up in the late iterations of a congested design)
    [ -n "${GRT_ALLOW:-}" ] && ovr+=$'\n'"set ::env(GRT_ALLOW_CONGESTION) $GRT_ALLOW"
    # DRT_ITERS=N: cap on detailed-routing optimisation iterations (default 64)
    [ -n "${DRT_ITERS:-}" ] && ovr+=$'\n'"set ::env(DRT_OPT_ITERS) $DRT_ITERS"
    [ -n "${GLB_RSZ_DESIGN:-}" ] && ovr+=$'\n'"set ::env(GLB_RESIZER_DESIGN_OPTIMIZATIONS) $GLB_RSZ_DESIGN"
    [ -n "${GLB_RSZ_TIMING:-}" ] && ovr+=$'\n'"set ::env(GLB_RESIZER_TIMING_OPTIMIZATIONS) $GLB_RSZ_TIMING"
    # detailed-router seeds, tried in turn until one routes clean (resume.tcl);
    # DRT_SEEDS="7 23 101" or DRT_SEED=7 (then 23 and 101 follow). Not 42: that
    # is the seed the normal flow already used.
    local seeds=${DRT_SEEDS:-"${DRT_SEED:-7} 23 101"}
    ovr+=$'\n'"set ::env(GEMM_DRT_SEEDS) \"$seeds\""
    ovr+=$'\n'"set ::env(DRT_OR_SEED) ${seeds%% *}"
    route_overrides
    # antenna ECO round 0: diodes for the violations an earlier route of this
    # same post-CTS netlist had, before the first global route
    if [ "${ANT_ECO:-3}" != 0 ]; then
        local arpt=${ANT_RPT:-}
        [ -n "$arpt" ] || arpt=$(ls -t "$src"/reports/signoff/*antenna_violators.rpt \
            "$OL/designs/gemm_core/runs/${from}_check"/reports/signoff/*antenna_violators.rpt 2>/dev/null | head -1)
        if [ -n "$arpt" ] && [ -f "$arpt" ]; then
            echo "  antenna ECO round 0 from ${arpt#"$OL"/} ($(grep -c 'Partial/Required' "$arpt") violations)"
            ovr+=$'\n'"set ::env(GEMM_ANT_ECO_RPT) \"${arpt/#$OL\//\/openlane\/}\""
        fi
    fi
    printf '%s\n' "$ovr" > "$HERE/designs/gemm_core/overrides.tcl"
    sed 's/^/  overrides: /' "$HERE/designs/gemm_core/overrides.tcl"
    local fp_args; fp_args=$(cat "$STATE/core_gen_args_$from.txt" 2>/dev/null)
    CORE_GEN_ARGS=$fp_args core_install || exit 1
    same_floorplan "$src" || exit 1
    echo "$fp_args" > "$STATE/core_gen_args_$tag.txt"
    echo "$tag" > "$STATE/core_last_tag.txt"
    write_resume_params "$from" "$tag" route
    local log=$HERE/logs/gemm_core_route_${tag}_$STAMP.log
    ol_resume "$log" || true
    RUNDIR=$OL/designs/gemm_core/runs/$tag
    # the GRT timing repair runs the same global route, then repair_timing: if
    # that step dies the same way, retry once without it
    python3 "$KIT/tools/core_triage.py" "$RUNDIR" > "$STATE/triage_$tag.txt"
    local last; last=$(sed -n 's/^last log *: \([^ ]*\).*/\1/p' "$STATE/triage_$tag.txt")
    local s2; s2=$(triage_field "$STATE/triage_$tag.txt" stage)
    if [[ "$last" == *resizer_timing* || "$last" == *resizer_design* ]] && [[ "$s2" =~ ^(rsz|dpl|after-dpl)$ ]] \
       && ! grep -q "GLB_RESIZER_TIMING_OPTIMIZATIONS) 0" "$HERE/designs/gemm_core/overrides.tcl"; then
        echo "  $tag died in ${last##*/} after global routing - retrying once without both GRT resizer steps"
        printf '%s\nset ::env(GLB_RESIZER_DESIGN_OPTIMIZATIONS) 0\nset ::env(GLB_RESIZER_TIMING_OPTIMIZATIONS) 0\n' \
            "$ovr" > "$HERE/designs/gemm_core/overrides.tcl"
        CORE_GEN_ARGS=$fp_args core_install || exit 1
        write_resume_params "$from" "$tag" route
        ol_resume "${log%.log}_retry.log" || true
    fi
    rm -f "$HERE/designs/gemm_core/overrides.tcl" "$OL/designs/gemm_core/overrides.tcl"
    core_verdict
}

core_verdict() {
    FAILS=0      # see array_verdict
    local placed want
    placed=$(grep -rhoE "Successfully placed [0-9]+ instances" "$RUNDIR/logs" 2>/dev/null | tail -1 | awk '{print $3}')
    want=$(awk '/GEMM_CORE_MACROS/{print $3}' "$HERE/designs/gemm_core/sizes.tcl")
    [ "${placed:-0}" = "$want" ] && pass "$want hard macros placed" || fail "placed '${placed:-0}' hard macros, expected $want"
    check_run "$RUNDIR" --waive-io-timing
    NOTE="GDS: ${RUNDIR#"$OL"/}/results/final/gds/GemmAccelerator.gds (I/O timing waived)"
    [ $FAILS -eq 0 ] && echo "$RUNDIR" > "$STATE/core_run.txt"    # core-gls / core-check use it
    finish core
}

st_core_gls() {   # original testbench on the final netlist, 3 matrix shapes, cycles vs the FPGA RTL
    need sim
    local run
    if [ -n "${TAG:-}" ]; then run=$OL/designs/gemm_core/runs/$TAG
    else run=$(ls -td "$OL"/designs/gemm_core/runs/*/results/final/verilog/gl 2>/dev/null | head -1); run=${run%/results/final/verilog/gl}; fi
    [ -f "$run/results/final/verilog/gl/GemmAccelerator.nl.v" ] \
        || { echo "no core run with results/final/verilog/gl/GemmAccelerator.nl.v (TAG=<run> to pick one)"; exit 1; }
    # rows as their gate netlist by default: with rtl rows a bad row netlist goes unseen
    export ROW=${ROW:-gl}
    say "core-gls: original testbench on the netlist of ${run#"$OL"/} (rows: $ROW)"
    local out=$HERE/logs/core_gls_$STAMP; mkdir -p "$out"
    local shape tag t0
    # "" = the testbench's own 64x64x64; the other two reach the second bank of the 1024-word memories
    for shape in "" "8,32,544" "16,992,32"; do
        tag=${shape:+_M$(echo "$shape" | awk -F, '{print $1"K"$2"N"$3}')}
        TB_SHAPE="$shape" "$KIT/sim/run_system.sh" orig "$REPO" > "$out/sys$tag.log" 2>&1 || true
        grep -E "RESULT_VALID_FIRST|RESULT_ACCEPT" "$KIT/sim/build_system_orig$tag/system.log" > "$out/cycles_orig$tag.txt" 2>/dev/null
        t0=$(date +%s)
        if TB_SHAPE="$shape" BUILD="$KIT/sim/build_gls$tag" OL=$OL "$KIT/sim/run_gls.sh" "$run" "$REPO" > "$out/gls$tag.log" 2>&1; then
            pass "${shape:-64,64,64}: OVERALL PASS ($(( $(date +%s) - t0 )) s)"
        else fail "${shape:-64,64,64}: gate-level sim failed (see ${out#"$KIT"/}/gls$tag.log)"; tail -n 4 "$out/gls$tag.log" | sed 's/^/    /'; fi
        cp "$KIT/sim/build_gls$tag/cycles_gls.txt" "$out/cycles_gls$tag.txt" 2>/dev/null
        if [ -s "$out/cycles_orig$tag.txt" ] && diff -q "$out/cycles_orig$tag.txt" "$out/cycles_gls$tag.txt" >/dev/null 2>&1; then
            pass "${shape:-64,64,64}: same cycle for all $(wc -l < "$out/cycles_orig$tag.txt") result events as the FPGA RTL"
        else fail "${shape:-64,64,64}: result cycles differ from the FPGA RTL"; fi
    done
    NOTE="${run##*/}, logs in ${out#"$KIT"/}"
    finish core-gls
}

# =========================================================================
# AXI accelerator IP: GEMM_top (rtl_asic/axi) = GemmAxiShell + GemmAccelerator
st_axi_sim() {
    need sim
    say "axi-sim: AXI IP RTL - skid buffer unit test, original testbench (thin, reg, reg + OpenRAM, 3 shapes)"
    local out=$HERE/logs/axi_sim_$STAMP; mkdir -p "$out"
    if "$KIT/sim/run_axi.sh" "$REPO" 2>&1 | tee "$out/run_axi.log"; [ "${PIPESTATUS[0]}" -eq 0 ]; then
        pass "sim/run_axi.sh: ALL PASS"
    else fail "sim/run_axi.sh (see ${out#"$KIT"/}/run_axi.log)"; fi
    cp "$KIT"/sim/build_axi/cycles_*.txt "$out/" 2>/dev/null || true
    NOTE="logs in ${out#"$KIT"/}"
    finish axi-sim
}

st_axi_shell() {
    need axi-sim
    # AXI_SHELL_VARIANTS: which stream variants to harden (thin reg reg_cg lean lean_cg)
    local variants=${AXI_SHELL_VARIANTS:-"thin reg lean lean_cg"}
    say "axi-shell: GemmAxiShell alone ($variants) - what the AXI interface costs"
    ol_patches || { fail "patch OpenLane scripts"; finish axi-shell; }
    local d=$OL/designs/gemm_axi_shell v r c runs=()
    python3 "$HERE/gen_axi_files.py" --out "$HERE/designs" || { fail "gen_axi_files.py"; finish axi-shell; }
    # only this design is copied (install_into_openlane.sh would also regenerate the core floorplan)
    mkdir -p "$d/src"
    cp "$HERE/designs/gemm_common.tcl" "$OL/designs/"
    cp "$HERE"/designs/gemm_axi_shell/* "$d/"
    cp "$KIT"/rtl_asic/*.v "$KIT"/rtl_asic/*.vh "$KIT"/rtl_asic/axi/*.v "$d/src/"
    for v in $variants; do
        case "$v" in
            thin) r=0; c=0 ;; reg) r=1; c=0 ;; reg_cg) r=1; c=1 ;; lean) r=2; c=0 ;; lean_cg) r=2; c=1 ;;
            *) fail "unknown variant $v (thin reg reg_cg lean lean_cg)"; continue ;;
        esac
        printf "set ::env(GEMM_AXIS_REG) %s   ;# written by run_flow.sh axi-shell\nset ::env(GEMM_AXIS_CG)  %s\n" "$r" "$c" > "$d/variant.tcl"
        # 1) calibration run with ideal outside clocks, only to measure the shell's clock latency
        rm -f "$d/clk_latency.tcl"
        ol_run gemm_axi_shell "shell_${v}_cal"
        if python3 "$KIT/tools/clock_latency.py" "$RUNDIR" "$d/clk_latency.tcl" > "$HERE/logs/axi_shell_lat_${v}_$STAMP.log" 2>&1; then
            pass "shell_$v clock latency: $(grep -o 'MIN) [0-9.]*\|MAX) [0-9.]*' "$d/clk_latency.tcl" | tr '\n' ' ')"
        else fail "shell_$v: could not measure the clock latency (see openlane/logs/axi_shell_lat_${v}_$STAMP.log)"; rm -f "$d/clk_latency.tcl"; fi
        # 2) the measured run: port delays from that latency (shell.sdc)
        ol_run gemm_axi_shell "shell_$v"
        check_run "$RUNDIR" --waive-io-timing
        runs+=("$d/runs/shell_$v")
        # 3) power: OpenSTA default activity, then activity from the original testbench
        #    (the shell's gate netlist in GEMM_top): the core's VCD window and the whole run
        if "$KIT/tools/axi_shell_power.sh" "$RUNDIR" > "$HERE/logs/axi_shell_power_${v}_$STAMP.log" 2>&1; then
            pass "shell_$v power, vectorless: $(grep -E '^Total' "$RUNDIR/reports/power/vectorless.design.rpt" | awk '{print $5" W"}')"
        else fail "shell_$v vectorless power (see openlane/logs/axi_shell_power_${v}_$STAMP.log)"; fi
        local w
        for w in "2300 3200" "0 end"; do
            set -- $w
            if "$KIT/tools/axi_shell_power.sh" "$RUNDIR" --vcd "$1" "$2" >> "$HERE/logs/axi_shell_power_${v}_$STAMP.log" 2>&1; then
                pass "shell_$v power, VCD cycles $1..$2: $(grep -E '^Total' "$RUNDIR/reports/power/vcd_${1}_$2.design.rpt" | awk '{print $5" W"}')"
            else fail "shell_$v VCD power $1..$2 (see openlane/logs/axi_shell_power_${v}_$STAMP.log)"; fi
        done
    done
    rm -f "$d/variant.tcl" "$d/clk_latency.tcl"
    local core=${CORE_RUN:-$(core_best_run)} md=$HERE/logs/axi_overhead_$STAMP.md
    [ -f "$core/reports/power/vectorless.design.rpt" ] \
        || echo "  (no vectorless power report in ${core#"$OL"/} yet - run: tools/power.sh $core)"
    if python3 "$KIT/tools/axi_overhead.py" "$core" "${runs[@]}" --md "$md" \
           --row "${ROW_RUN:-$OL/designs/gemm_row/runs/row_v1}"; then
        pass "overhead table: ${md#"$KIT"/}"
    else fail "tools/axi_overhead.py"; fi
    NOTE="overhead table ${md#"$KIT"/}"
    finish axi-shell
}

st_axi_gls() {
    need axi-sim
    # AXI_GLS_WRAP (thin|reg|lean) and AXI_GLS_CG (0|1): the wrapper simulated around the core netlist
    local wrap=${AXI_GLS_WRAP:-lean} cg=${AXI_GLS_CG:-1}
    local core=${CORE_RUN:-$(core_best_run)} shape tag out=$HERE/logs/axi_gls_$STAMP b
    mkdir -p "$out"
    say "axi-gls: GEMM_top ($wrap, CG=$cg) RTL around the final netlist of ${core##*/}, rows gate-level"
    # AXI_GLS_SHAPES="8,32,544 16,992,32" adds the other two shapes (~10 and ~22 min more)
    for shape in "" ${AXI_GLS_SHAPES:-}; do
        tag=${shape:+_M$(echo "$shape" | awk -F, '{print $1"K"$2"N"$3}')}
        b=$KIT/sim/build_gls_axi${wrap}$([ "$cg" = 1 ] && echo cg)$tag
        if WRAP=$wrap AXIS_CG=$cg ROW=${ROW:-gl} TB_SHAPE="$shape" BUILD="$b" OL=$OL \
               "$KIT/sim/run_gls.sh" "$core" "$REPO" > "$out/gls$tag.log" 2>&1; then
            pass "GEMM_top $wrap CG=$cg + ${core##*/}${shape:+ ($shape)}: OVERALL PASS, $(wc -l < "$b/cycles_gls.txt") result events"
        else fail "GEMM_top $wrap CG=$cg + ${core##*/}${shape:+ ($shape)} (see ${out#"$KIT"/}/gls$tag.log)"; fi
    done
    NOTE="$wrap CG=$cg, ${core##*/}, logs in ${out#"$KIT"/}"
    finish axi-gls
}

# =========================================================================
# complete IP: GEMM_top = GemmAxiShell hardened as a macro (gemm_ip_shell)
#              + GemmAccelerator synthesised flat as in gemm_core (gemm_ip),
# on the core_v11 floorplan moved by (DX, DY) (gen_ip_files.py)
IP_SHELL_D=$OL/designs/gemm_ip_shell
IP_D=$OL/designs/gemm_ip

ip_core_run() { echo "$OL/designs/gemm_core/runs/${IP_CORE_TAG:-core_v11}"; }

ip_floorplan() {   # macro + IP floorplan files, from the floorplan options of the core run
    local tag=${IP_CORE_TAG:-core_v11} args def chk=()
    args=$(cat "$STATE/core_gen_args_$tag.txt" 2>/dev/null)
    [ -n "$args" ] || args=$CORE_GEN_DEFAULT
    def=$(ls "$(ip_core_run)"/results/final/def/*.def 2>/dev/null | head -1)
    [ -n "$def" ] && chk=(--check-def "$def")
    python3 "$HERE/gen_ip_files.py" --pe-area "$(cat "$STATE/pe_area.txt")" --core-args "$args" \
        --row-lef "$OL/designs/gemm_row/runs/row_v1/results/final/lef/ProcessingElementRow.lef" \
        --result-top "${IP_RESULT_TOP:-640}" "${chk[@]}" --out "$HERE/designs"
}

ip_common_install() {   # the gemm_core / gemm_axi_shell files the two IP designs source
    local f
    cp "$HERE/designs/gemm_common.tcl" "$OL/designs/"
    mkdir -p "$OL/designs/gemm_core" "$OL/designs/gemm_axi_shell"
    for f in config.tcl core.sdc keep_rows_clear.tcl PE_row_bb.v sram_bb.v route_signoff.tcl grt_probe.tcl; do
        cp "$HERE/designs/gemm_core/$f" "$OL/designs/gemm_core/" || return 1
    done
    for f in config.tcl shell.sdc dlclkp_bb.v; do
        cp "$HERE/designs/gemm_axi_shell/$f" "$OL/designs/gemm_axi_shell/" || return 1
    done
}

ip_shell_install() {
    ip_common_install || return 1
    mkdir -p "$IP_SHELL_D/src"
    cp "$HERE"/designs/gemm_ip_shell/{config.tcl,shell_full.tcl,ant_seed.py,sizes.tcl,pin_order.cfg} "$IP_SHELL_D/" || return 1
    # route_signoff.tcl looks for these in DESIGN_DIR
    cp "$HERE"/designs/gemm_core/macro_cross.py "$IP_SHELL_D/" || return 1
    # ant_eco.py = ant_eco_max.py (passes GEMM_ANT_ECO_MAX_TOTAL) around the core's script
    cp "$HERE"/designs/gemm_core/ant_eco.py "$IP_SHELL_D/ant_eco_core.py" || return 1
    cp "$HERE"/designs/gemm_ip_shell/ant_eco_max.py "$IP_SHELL_D/ant_eco.py" || return 1
    cp "$KIT"/rtl_asic/*.v "$KIT"/rtl_asic/*.vh "$KIT"/rtl_asic/axi/*.v "$IP_SHELL_D/src/"
}

ip_shell_run() {   # the AXI macro run the IP uses
    local r=""
    [ -f "$STATE/ip_shell_run.txt" ] && r=$(cat "$STATE/ip_shell_run.txt")
    echo "${r:-$IP_SHELL_D/runs/${IP_SHELL_TAG:-ip_shell}}"
}

ip_ol_full() {   # ip_ol_full <design> <dir> <tcl> <tag> <log prefix>: interactive full run
    local design=$1 dir=$2 tcl=$3 tag=$4
    local log=$HERE/logs/${5}_${tag}_$STAMP.log
    [ -f "$OL/flow.tcl" ] || { echo "OpenLane not found at $OL (set OL=...)"; exit 1; }
    printf '# written by run_flow.sh %s for designs/%s/%s\nset GEMM_NEW_TAG %s\n' "$STAMP" "$design" "$tcl" "$tag" \
        > "$dir/full_params.tcl"
    echo "  OpenLane ($tcl): $design (tag $tag) - log: ${log#"$KIT"/}"
    mem_watch_start "$HERE/logs/mem_${design}_${tag}_$STAMP.txt"
    make -C "$OL" quick_run QUICK_RUN_DESIGN="$design -it -file designs/$design/$tcl" 2>&1 | tee "$log"
    local rc=${PIPESTATUS[0]}
    mem_watch_stop
    [ "$rc" -eq 0 ] || fail "OpenLane run $design/$tag stopped (see the log above)"
    RUNDIR=$OL/designs/$design/runs/$tag
}

st_ip_shell() {
    need axi-sim
    local tag=${IP_SHELL_TAG:-ip_shell}
    say "ip-shell: the AXI macro of the IP (GemmAxiShell lean + clock gating, met1-met4), run $tag"
    ol_patches || { fail "patch OpenLane scripts"; finish ip-shell; }
    local rc=0
    ip_floorplan > "$STATE/ip_floorplan.txt" || rc=$?
    sed 's/^/  /' "$STATE/ip_floorplan.txt"
    [ $rc -eq 0 ] || { fail "gen_ip_files.py (floorplan / pin alignment)"; finish ip-shell; }
    ip_shell_install || { fail "install gemm_ip_shell into $OL"; finish ip-shell; }
    rm -f "$IP_SHELL_D/overrides.tcl"
    # 1) calibration run: the macro's own clock latency for its port delays (as axi-shell)
    # Only the clock tree matters here. With the ideal outside clock of this run every
    # input misses hold by the whole latency, and on a 160 um wide die the ~6400 hold
    # buffers the resizer adds do not fit next to the West pins (first try: DPL-0036
    # legalizing the port diodes). So no timing repair in this run.
    rm -f "$IP_SHELL_D/clk_latency.tcl"
    printf 'set ::env(PL_RESIZER_TIMING_OPTIMIZATIONS) 0\nset ::env(GLB_RESIZER_TIMING_OPTIMIZATIONS) 0\n' \
        > "$IP_SHELL_D/overrides.tcl"
    ol_run gemm_ip_shell "${tag}_cal"
    rm -f "$IP_SHELL_D/overrides.tcl"
    if python3 "$KIT/tools/clock_latency.py" "$RUNDIR" "$IP_SHELL_D/clk_latency.tcl" > "$HERE/logs/ip_shell_lat_$STAMP.log" 2>&1; then
        pass "macro clock latency: $(grep -o 'MIN) [0-9.]*\|MAX) [0-9.]*' "$IP_SHELL_D/clk_latency.tcl" | tr '\n' ' ')"
        awk '/GEMM_CLK_LAT_MAX/{print $3}' "$IP_SHELL_D/clk_latency.tcl" > "$STATE/ip_shell_lat.txt"
    else fail "could not measure the macro clock latency (see openlane/logs/ip_shell_lat_$STAMP.log)"; finish ip-shell; fi
    FAILS=0     # the calibration run is not judged
    # 2) the real run: flow up to CTS + gemm_core/route_signoff.tcl (antenna ECO rounds)
    ip_ol_full gemm_ip_shell "$IP_SHELL_D" shell_full.tcl "$tag" gemm_ip_shell
    FAILS=0
    # internal timing at Typical (the port budget is the IP's business, see ip.sdc)
    check_run "$RUNDIR" --waive-io-timing
    python3 "$KIT/tools/sta_corners.py" "$RUNDIR" > "$HERE/logs/ip_shell_corners_$STAMP.txt" 2>&1 || true
    local fin=$RUNDIR/results/final lef=$HERE/designs/gemm_ip/GemmAxiShell_antenna.lef
    # 3) antenna data on every signal pin of the macro LEF (the IP's antenna check reads it)
    mkdir -p "$HERE/designs/gemm_ip"
    if python3 "$KIT/tools/lef_antenna_pins.py" "$fin/lef/GemmAxiShell.lef" GemmAxiShell; then
        cp "$fin/lef/GemmAxiShell.lef" "$lef"
        pass "macro LEF: antenna data on every signal pin"
    else
        local lib=""
        for r in "${PDK_ROOT:-}" "$HOME/.ciel" "$HOME/.volare" "$OL/pdks"; do
            [ -n "$r" ] && [ -f "$r/${PDK:-sky130A}/libs.ref/sky130_fd_sc_hd/lef/sky130_fd_sc_hd.lef" ] \
                && { lib=$r/${PDK:-sky130A}/libs.ref/sky130_fd_sc_hd/lef/sky130_fd_sc_hd.lef; break; }
        done
        if [ -n "$lib" ] && python3 "$HERE/designs/gemm_core/macro_antenna_lef.py" --in "$fin/lef/GemmAxiShell.lef" \
               --lib-lef "$lib" --out "$lef" && python3 "$KIT/tools/lef_antenna_pins.py" "$lef" GemmAxiShell; then
            pass "macro LEF: antenna data added by macro_antenna_lef.py on the pins that had none (${lef#"$KIT"/})"
        else fail "macro LEF without antenna data on some pins"; fi
    fi
    # 4) the original testbench on GEMM_top with the macro's final netlist + the core RTL
    if "$KIT/tools/axi_shell_power.sh" "$RUNDIR" --vcd 0 end > "$HERE/logs/ip_shell_gls_$STAMP.log" 2>&1 \
       && grep -q "OVERALL PASS" "$KIT/sim/build_shell_power/${tag}_vcd_0_end/sim.log"; then
        pass "testbench on GEMM_top (macro netlist + core RTL): OVERALL PASS (openlane/logs/ip_shell_gls_$STAMP.log)"
    else fail "testbench with the macro netlist (see openlane/logs/ip_shell_gls_$STAMP.log)"; fi
    "$KIT/tools/axi_shell_power.sh" "$RUNDIR" >> "$HERE/logs/ip_shell_gls_$STAMP.log" 2>&1 || true
    # 5) the IP top + the port view of the macro, from this netlist
    python3 "$HERE/gen_ip_files.py" --rtl "$fin/verilog/gl/GemmAxiShell.nl.v" --out "$HERE/designs" \
        || fail "gen_ip_files.py --rtl"
    [ $FAILS -eq 0 ] && echo "$RUNDIR" > "$STATE/ip_shell_run.txt"
    NOTE="${RUNDIR#"$OL"/}: $(head -c 300 "$STATE/ip_floorplan.txt" | sed -n 3p)"
    finish ip-shell
}

ip_latency() {   # clk_latency.tcl of the IP: core flops (core run) + the AXI macro's own latency
    local core lat_c lat_s tmp
    core=$(ip_core_run); tmp=$(mktemp)
    if python3 "$KIT/tools/clock_latency.py" "$core" "$tmp" > /dev/null 2>&1; then
        lat_c=$(awk '/GEMM_CLK_LAT_MAX/{print $3}' "$tmp")
    else lat_c=5.16; fi
    rm -f "$tmp"
    lat_s=$(cat "$STATE/ip_shell_lat.txt" 2>/dev/null); lat_s=${lat_s:-0}
    {
        echo "# written by run_flow.sh $STAMP: every AXI port faces a flop inside u_axi_shell, clocked"
        echo "# at the clock of the core's flops (${core##*/}: median $lat_c ns, CTS balances the macro"
        echo "# clock pin with them) + the macro's own latency ($lat_s ns, ip-shell calibration run)"
        echo "set ::env(GEMM_CLK_LAT_MIN) $(awk -v a="$lat_c" -v b="$lat_s" 'BEGIN{printf "%.2f", a + b}')"
        echo "set ::env(GEMM_CLK_LAT_MAX) $(awk -v a="$lat_c" -v b="$lat_s" 'BEGIN{printf "%.2f", a + b}')"
    } > "$HERE/designs/gemm_ip/clk_latency.tcl"
    sed -n 4,5p "$HERE/designs/gemm_ip/clk_latency.tcl" | sed 's/^/  port latency: /'
}

ip_install() {   # everything gemm_ip needs in $OL (floorplan files must already be generated)
    local shell sram="" lib="" f
    shell=$(ip_shell_run)
    [ -f "$shell/results/final/gds/GemmAxiShell.gds" ] || { echo "  no AXI macro in $shell - run ip-shell first"; return 1; }
    ip_common_install || return 1
    for root in "${PDK_ROOT:-}" "$HOME/.volare" "$HOME/.ciel" "$OL/pdks"; do
        [ -n "$root" ] && [ -f "$root/${PDK:-sky130A}/libs.ref/sky130_sram_macros/lef/sky130_sram_2kbyte_1rw1r_32x512_8.lef" ] \
            && { sram=$root/${PDK:-sky130A}/libs.ref/sky130_sram_macros; lib=$root/${PDK:-sky130A}/libs.ref/sky130_fd_sc_hd/lef/sky130_fd_sc_hd.lef; break; }
    done
    [ -n "$sram" ] || { echo "  OpenRAM macro LEF not found"; return 1; }
    mkdir -p "$IP_D/src"
    # same annotated SRAM LEF as core_install writes for gemm_core
    python3 "$HERE/designs/gemm_core/macro_antenna_lef.py" --in "$sram/lef/sky130_sram_2kbyte_1rw1r_32x512_8.lef" \
        --lib-lef "$lib" --out "$IP_D/sram_antenna.lef" > /dev/null || return 1
    for f in config.tcl ip.sdc ip_post_cts.sdc ip_hold_fix.tcl ip_write_sdc.tcl ip_droute.tcl cfg_shift_mcp.sdc clk_latency_seed.tcl ip_pre.tcl ip_full.tcl ip_resume.tcl \
             ip_route_signoff.tcl ip_timing_eco.tcl sizes.tcl macro.cfg pin_order.cfg floorplan.txt GEMM_top_ip.v GemmAxiShell_bb.v GemmAxiShell_antenna.lef; do
        cp "$HERE/designs/gemm_ip/$f" "$IP_D/" || { echo "  missing openlane/designs/gemm_ip/$f"; return 1; }
    done
    [ -f "$HERE/designs/gemm_ip/clk_latency.tcl" ] && cp "$HERE/designs/gemm_ip/clk_latency.tcl" "$IP_D/"
    cp "$HERE"/designs/gemm_core/{ant_eco.py,macro_cross.py} "$IP_D/" || return 1
    cp "$KIT"/rtl_asic/*.v "$KIT"/rtl_asic/*.vh "$IP_D/src/"
    # the IP top next to gemm_asic_cfg.vh: the linter finds includes only relative to the file
    mv "$IP_D/GEMM_top_ip.v" "$IP_D/src/" || return 1
    # the macro run, as the container sees it (relative to the design dir)
    printf '# written by run_flow.sh %s\nset ::env(GEMM_IP_SHELL_RUN) $::env(DESIGN_DIR)/../gemm_ip_shell/runs/%s\n' \
        "$STAMP" "${shell##*/}" > "$IP_D/shell_run.tcl"
}

grt_overflow() {   # grt_overflow <log>: total overflow of the GRT-0096 table (last one in the log)
    grep -A12 "GRT-0096" "$1" 2>/dev/null | awk '/^Total/{v=$NF} END{print (v == "" ? "-" : v)}'
}

st_ip_pre() {
    need ip-shell
    say "ip-pre: GEMM_top lint + synthesis + floorplan + placement + global route"
    ip_floorplan > "$STATE/ip_floorplan.txt" || { cat "$STATE/ip_floorplan.txt"; fail "gen_ip_files.py"; finish ip-pre; }
    sed 's/^/  /' "$HERE/designs/gemm_ip/floorplan.txt"
    ol_patches || { fail "patch OpenLane scripts"; finish ip-pre; }
    ip_latency
    rm -f "$HERE/designs/gemm_ip/overrides.tcl" "$IP_D/overrides.tcl"
    ip_install || { fail "install gemm_ip into $OL"; finish ip-pre; }
    local log=$HERE/logs/gemm_ip_pre_$STAMP.log run=$IP_D/runs/ip_pre
    echo "  OpenLane (ip_pre.tcl) - log: ${log#"$KIT"/}"
    mem_watch_start "$HERE/logs/mem_gemm_ip_ip_pre_$STAMP.txt"
    make -C "$OL" quick_run QUICK_RUN_DESIGN="gemm_ip -it -file designs/gemm_ip/ip_pre.tcl" 2>&1 | tee "$log"
    local rc=${PIPESTATUS[0]}
    mem_watch_stop; PEAK=${MEMPEAK:--}
    if [ "$rc" -eq 0 ] && grep -q "GEMM_IP_PRE_DONE" "$log"; then pass "lint, synthesis, floorplan, placement, global route completed"
    else fail "ip_pre.tcl stopped - first error:"; grep -m3 -E "\[ERROR|Error:" "$log" | sed 's/^/    /'; fi
    # netlist: 80 SRAM, 32 rows, 1 AXI macro, macro names as macro.cfg expects
    local net; net=$(ls "$run"/results/synthesis/*.v 2>/dev/null | head -1)
    if [ -n "$net" ]; then
        local ns nr na
        ns=$(grep -cE "^\s*sky130_sram_2kbyte_1rw1r_32x512_8\s" "$net")
        nr=$(grep -cE "^\s*ProcessingElementRow\s" "$net")
        na=$(grep -cE "^\s*GemmAxiShell\s+u_axi_shell\b" "$net")
        [ "$ns" = 80 ] && [ "$nr" = 32 ] && [ "$na" = 1 ] && pass "netlist: 80 OpenRAM, 32 row macros, 1 AXI macro (u_axi_shell)" \
            || fail "netlist has $ns OpenRAM, $nr row, $na AXI macros (expected 80, 32, 1)"
        grep -m1 -oE "\\\\u_gemm_accelerator\.u_buffer_feeder\.u_compute_core\.u_processing_element_array\.g_pe_row\[0\]\.u_row" "$net" \
            | sed 's/^/  row 0 is named /'
    else fail "no synthesis netlist in $run/results/synthesis"; fi
    local placed want
    placed=$(grep -rhoE "Successfully placed [0-9]+ instances" "$run/logs" 2>/dev/null | tail -1 | awk '{print $3}')
    want=$(awk '/GEMM_IP_MACROS/{print $3}' "$HERE/designs/gemm_ip/sizes.tcl")
    [ "${placed:-0}" = "$want" ] && pass "$want hard macros placed from macro.cfg" \
        || fail "macro placement placed '${placed:-0}', expected $want"
    # where the macros really are: counts, overlaps, positions = macro.cfg
    local def; def=$(ls -t "$run"/results/placement/*.def "$run"/tmp/routing/*global.def 2>/dev/null | head -1)
    if [ -n "$def" ] && python3 "$KIT/tools/macro_place_check.py" "$def" "$run/tmp/merged.nom.lef" --cfg "$IP_D/macro.cfg" \
           --expect sky130_sram_2kbyte_1rw1r_32x512_8=80 ProcessingElementRow=32 GemmAxiShell=1 | sed 's/^/  /'; then
        pass "32 rows + 80 SRAM + 1 AXI macro where macro.cfg puts them, no overlap"
    else fail "macro placement check (${def:-no DEF})"; fi
    grep -h "keep_rows_clear" "$run"/logs/*/*.log 2>/dev/null | tail -n 1 | sed 's/^ *\[INFO\]: /  /'
    # global route: macro crossings and overflow vs the core run's first global route
    local mc; mc=$(sed -n 's/.*GEMM_IP_MACRO_CROSS exit \([0-9]*\).*/\1/p' "$log" | tail -1)
    grep -E "^RESULT:|nets THROUGH" "$log" | tail -n 2 | sed 's/^/  macro_cross: /'
    [ "$mc" = 0 ] && pass "macro_cross: no net through a macro" || fail "macro_cross exit '${mc:-none}' (see $run/reports/routing/macro_cross.rpt)"
    local ip_of core_of glog clog
    glog=$(ls "$run"/logs/routing/*-global.log 2>/dev/null | sort -t- -k1,1n | tail -1)
    clog=$(ls "$(ip_core_run)"/logs/routing/*-global.log 2>/dev/null | sort -V | head -1)
    ip_of=$(grt_overflow "$glog"); core_of=$(grt_overflow "$clog")
    echo "  global route overflow: IP $ip_of (before CTS, ${glog##*/}), ${IP_CORE_TAG:-core_v11} $core_of (after CTS, ${clog##*/})"
    if [ "$ip_of" != "-" ] && [ "$core_of" != "-" ] && [ "$ip_of" -le $(( core_of * 3 / 2 + 20 )) ]; then
        pass "global route overflow $ip_of, not clearly worse than ${IP_CORE_TAG:-core_v11} ($core_of)"
    else fail "global route overflow $ip_of vs ${IP_CORE_TAG:-core_v11} $core_of"; fi
    grep -A10 "GRT-0096" "$glog" 2>/dev/null | sed -n '1,10p' | sed 's/^/    /'
    NOTE="ip_pre: overflow $ip_of (core_v11 $core_of), macro_cross exit ${mc:-none}"
    finish ip-pre
}

ip_last_tag() { local t=""; [ -f "$STATE/ip_last_tag.txt" ] && t=$(cat "$STATE/ip_last_tag.txt"); echo "${t:-ip_v1}"; }

st_ip() {
    need ip-pre
    local tag=${IP_TAG:-ip_v1}
    say "ip: GEMM_top full run (AXI macro + 32 rows + 80 OpenRAM), tag $tag - expect ~10 h"
    need_disk "${MIN_DISK_GB:-40}"
    echo "$tag" > "$STATE/ip_last_tag.txt"
    ip_floorplan > "$STATE/ip_floorplan.txt" || { fail "gen_ip_files.py"; finish ip; }
    ip_latency
    rm -f "$HERE/designs/gemm_ip/overrides.tcl" "$IP_D/overrides.tcl"
    local ovr="# written by run_flow.sh ip $STAMP"
    ovr+=$'\n'"set ::env(GEMM_DRT_SEEDS) \"${DRT_SEEDS:-42 7 23}\""
    [ -n "${IP_CLOCK_PERIOD:-}" ] && ovr+=$'\n'"set ::env(CLOCK_PERIOD) $IP_CLOCK_PERIOD"
    route_overrides
    printf '%s\n' "$ovr" > "$HERE/designs/gemm_ip/overrides.tcl"
    sed 's/^/  overrides: /' "$HERE/designs/gemm_ip/overrides.tcl"
    ol_patches || { fail "patch OpenLane scripts"; finish ip; }
    ip_install || { fail "install gemm_ip into $OL"; finish ip; }
    cp "$HERE/designs/gemm_ip/overrides.tcl" "$IP_D/"
    ip_ol_full gemm_ip "$IP_D" ip_full.tcl "$tag" gemm_ip
    # global placement can diverge (GPL-0307): retry once without timing-driven placement, as core
    if grep -qs "GPL-0307" "$RUNDIR"/logs/placement/*global*.log; then
        echo "  global placement diverged (GPL-0307) - retrying once with PL_TIME_DRIVEN 0"
        printf '%s\n# after GPL-0307 in the previous attempt\nset ::env(PL_TIME_DRIVEN) 0\n' "$ovr" > "$IP_D/overrides.tcl"
        FAILS=0
        ip_ol_full gemm_ip "$IP_D" ip_full.tcl "$tag" gemm_ip
    fi
    rm -f "$HERE/designs/gemm_ip/overrides.tcl" "$IP_D/overrides.tcl"
    local drc=$RUNDIR/reports/routing/drt.drc
    if [ -s "$drc" ] && grep -q "violation type" "$drc"; then
        echo "  $tag: detailed routing left $(grep -c 'violation type' "$drc") violation(s) with every seed -"
        echo "  routing again from its post-CTS layout with other router seeds (run ${tag}r)"
        FAILS=0
        FROM=$tag IP_TAG=${tag}r DRT_SEEDS="${DRT_SEEDS_RETRY:-101 211 307}" st_ip_route   # ends with ip_verdict
        return
    fi
    ip_verdict ip
}

ip_verdict() {   # ip_verdict <stage>: judge $RUNDIR as a complete IP (no I/O timing waiver)
    FAILS=0
    local placed want
    placed=$(grep -rhoE "Successfully placed [0-9]+ instances" "$RUNDIR/logs" 2>/dev/null | tail -1 | awk '{print $3}')
    want=$(awk '/GEMM_IP_MACROS/{print $3}' "$HERE/designs/gemm_ip/sizes.tcl")
    [ "${placed:-0}" = "$want" ] && pass "$want hard macros placed" || fail "placed '${placed:-0}' hard macros, expected $want"
    check_run "$RUNDIR"
    NOTE="GDS: ${RUNDIR#"$OL"/}/results/final/gds/GEMM_top.gds"
    [ -f "$RUNDIR/results/final/gds/GEMM_top.gds" ] && echo "$RUNDIR" > "$STATE/ip_run.txt"
    finish "$1"
}

ip_best_run() {
    local r=""
    [ -f "$STATE/ip_run.txt" ] && r=$(cat "$STATE/ip_run.txt")
    if [ -n "${IP_TAG:-}" ]; then echo "$IP_D/runs/$IP_TAG"; elif [ -n "$r" ] && [ -d "$r" ]; then echo "$r"
    else echo "$IP_D/runs/$(ip_last_tag)"; fi
}

st_ip_route() {   # routing + signoff from the post-CTS layout of an IP run (as core-route)
    need ip-pre
    local from=${FROM:-$(ip_last_tag)}
    local tag=${IP_TAG:-${from}r}
    local src=$IP_D/runs/$from
    say "ip-route: routing + signoff from the post-CTS layout of $from (new run $tag)"
    need_disk "${MIN_DISK_GB:-40}"
    [ -f "$src/config.tcl" ] || { echo "  no $src/config.tcl - nothing to continue from"; exit 1; }
    [ "$from" != "$tag" ] || { echo "  IP_TAG must differ from FROM"; exit 1; }
    ls "$src"/tmp/cts/*.resized.odb "$src"/results/cts/*.odb > /dev/null 2>&1 \
        || { echo "  $from has no post-CTS layout (tmp/cts/*.resized.odb) - run ip again"; exit 1; }
    local ovr="# written by run_flow.sh ip-route $STAMP (continuing $from)"
    [ -n "${GRT_ALLOW:-}" ] && ovr+=$'\n'"set ::env(GRT_ALLOW_CONGESTION) $GRT_ALLOW"
    [ -n "${DRT_ITERS:-}" ] && ovr+=$'\n'"set ::env(DRT_OPT_ITERS) $DRT_ITERS"
    local seeds=${DRT_SEEDS:-"${DRT_SEED:-7} 23 101"}
    ovr+=$'\n'"set ::env(GEMM_DRT_SEEDS) \"$seeds\""
    ovr+=$'\n'"set ::env(DRT_OR_SEED) ${seeds%% *}"
    [ -n "${IP_CLOCK_PERIOD:-}" ] && ovr+=$'\n'"set ::env(CLOCK_PERIOD) $IP_CLOCK_PERIOD"
    route_overrides
    # antenna ECO round 0 from the violators of an earlier route of the same netlist
    if [ "${ANT_ECO:-3}" != 0 ]; then
        local arpt=${ANT_RPT:-}
        [ -n "$arpt" ] || arpt=$(ls -t "$src"/reports/signoff/*antenna_violators.rpt 2>/dev/null | head -1)
        if [ -n "$arpt" ] && [ -f "$arpt" ]; then
            echo "  antenna ECO round 0 from ${arpt#"$OL"/} ($(grep -c 'Partial/Required' "$arpt") violations)"
            ovr+=$'\n'"set ::env(GEMM_ANT_ECO_RPT) \"${arpt/#$OL\//\/openlane\/}\""
        fi
    fi
    printf '%s\n' "$ovr" > "$HERE/designs/gemm_ip/overrides.tcl"
    sed 's/^/  overrides: /' "$HERE/designs/gemm_ip/overrides.tcl"
    ol_patches || exit 1
    ip_install || exit 1
    cp "$HERE/designs/gemm_ip/overrides.tcl" "$IP_D/"
    echo "$tag" > "$STATE/ip_last_tag.txt"
    cat > "$IP_D/resume_params.tcl" <<EOF
# written by run_flow.sh $STAMP for designs/gemm_ip/ip_resume.tcl
set GEMM_FROM_TAG    $from
set GEMM_NEW_TAG     $tag
set GEMM_MODE        route
set GEMM_PROBE_ITERS 0
EOF
    local log=$HERE/logs/gemm_ip_route_${tag}_$STAMP.log
    echo "  OpenLane (ip_resume.tcl) - log: ${log#"$KIT"/}"
    mem_watch_start "$HERE/logs/mem_gemm_ip_${tag}_$STAMP.txt"
    make -C "$OL" quick_run QUICK_RUN_DESIGN="gemm_ip -it -file designs/gemm_ip/ip_resume.tcl" 2>&1 | tee "$log"
    mem_watch_stop
    rm -f "$HERE/designs/gemm_ip/overrides.tcl" "$IP_D/overrides.tcl"
    RUNDIR=$IP_D/runs/$tag
    ip_verdict ip
}

st_ip_status() {   # where the running (or last) IP run is - reads files only, safe any time
    local tag=${IP_TAG:-$(ip_last_tag)}
    local run=$IP_D/runs/$tag
    say "ip-status: $tag"
    [ -d "$run" ] || { echo "  no run directory ${run#"$OL"/} yet"; return 0; }
    local now first step last f p
    now=$(date +%s)
    first=$(ls -tr "$run"/logs/synthesis/*.log 2>/dev/null | head -1)
    [ -n "$first" ] && printf "  running for  : %dh%02dm (since the first synthesis log)\n" \
        $(( (now - $(stat -c %Y "$first")) / 3600 )) $(( (now - $(stat -c %Y "$first")) % 3600 / 60 ))
    step=$(grep -ho "\[STEP [0-9]*\]" "$run"/openlane.log 2>/dev/null | tail -1)
    [ -n "$step" ] && echo "  last step    : $step  $(grep -hE '\[INFO\]: (Running|Starting|Skipping)' "$run"/openlane.log 2>/dev/null | tail -1 | sed 's/.*\[INFO\]: //')"
    grep -qs "flow failed\|\[ERROR\]" "$run"/openlane.log && echo "  !! openlane.log has an error: $(grep -h -m1 '\[ERROR\]' "$run"/openlane.log | cut -c1-150)"
    [ -f "$run/reports/metrics.csv" ] && echo "  flow finished: reports/metrics.csv written - run: openlane/run_flow.sh ip-check"
    last=$(ls -t "$run"/logs/*/*.log 2>/dev/null | head -1)
    if [ -n "$last" ]; then
        printf "  newest log   : %s (%s, updated %ds ago)\n" "${last#"$run"/}" "$(du -h "$last" | cut -f1)" $(( now - $(stat -c %Y "$last") ))
        tail -n 3 "$last" | cut -c1-150 | sed 's/^/      | /'
    fi
    for f in $(ls -tr "$run"/logs/routing/*.log 2>/dev/null); do
        grep -q "GRT-0096" "$f" || continue
        echo "  global route : ${f##*/}: total overflow $(grt_overflow "$f")"
    done
    f=$(ls -t "$run"/logs/routing/*detailed*.log 2>/dev/null | head -1)
    [ -n "$f" ] && echo "  detailed rt  : $(grep -hE 'Start .*(optimization iteration|routing)\.' "$f" | tail -1 | sed 's/.*\] //')  $(grep -h 'Number of violations' "$f" | tail -1 | sed 's/.*\] *//')"
    [ -s "$run/reports/routing/ant_eco_rounds.txt" ] && sed 's/^/  ECO         : /' "$run/reports/routing/ant_eco_rounds.txt"
    f=$(ls -t "$HERE"/logs/mem_gemm_ip_"$tag"_*.txt 2>/dev/null | head -1)
    [ -n "$f" ] && [ -s "$f" ] && echo "  memory now   : $(tail -n 1 "$f" | awk '{printf "%s: %s %s MB, free RAM %s MB, swap used %s MB", $1, $3, $2, $4, $5}')"
    [ -n "$f" ] && [ -s "$f" ] && echo "  memory peak  : $(awk '$2 > m {m = $2; c = $3} END {print m " MB (" c ")"}' "$f")"
    p=$(ps -eo etime=,rss=,comm= 2>/dev/null | awk '$3 ~ /^(openroad|yosys|magic|netgen|klayout)/ {printf "%s (%d MB, %s)  ", $3, $2/1024, $1}')
    echo "  EDA process  : ${p:-none running}"
    echo "  disk free: $(disk_free_gb) GB"
}

st_ip_check() {   # signoff of an IP run, every check that does not need OpenLane's flow
    need ip-pre
    RUNDIR=$(ip_best_run)
    say "ip-check: ${RUNDIR#"$OL"/}"
    [ -f "$RUNDIR/reports/metrics.csv" ] || { echo "  no reports/metrics.csv - the run did not finish"; exit 1; }
    local out=$HERE/logs/ip_check_${RUNDIR##*/}_$STAMP; mkdir -p "$out"
    # router DRC, Magic DRC, LVS, antenna, setup (spef_wns) and hold - no I/O timing waiver;
    # judged item by item, since Magic flags next to a macro get a second look below
    python3 "$HERE/check_openlane_run.py" "$RUNDIR" > "$out/check_openlane_run.txt" 2>&1
    cp "$out/check_openlane_run.txt" "$STATE/last_check.txt"
    sed 's/^/  /' "$out/check_openlane_run.txt"
    PEAK=$(awk -F'= ' '/Peak_Memory_Usage_MB/{split($2,a," "); print a[1]}' "$out/check_openlane_run.txt")
    local item v
    for item in tritonRoute_violations lvs_total_errors pin_antenna_violations; do
        grep -qE "^ *PASS +$item" "$out/check_openlane_run.txt" && pass "$item" \
            || fail "$item: $(grep -E " $item" "$out/check_openlane_run.txt" | sed 's/^ *//')"
    done
    # timing verdict (tools/timing_gate.py), by path kind (cell, SRAM, row, AXI macro, port):
    # macros timed at signoff, clock period = GEMM_GATE_PERIOD [10 ns], Typical setup of
    # every internal kind >= 0, I/O >= 0 or not worse than core_v11, hold >= 0 for every
    # kind at Typical and without a macro pin at Slowest/Fastest; Slowest setup only printed
    if python3 "$KIT/tools/timing_gate.py" "$RUNDIR" --ref "$(ip_core_run)" > "$out/timing_gate.txt" 2>&1; then
        pass "timing: $(tail -n 1 "$out/timing_gate.txt")"
    else fail "timing: $(tail -n 1 "$out/timing_gate.txt")"; fi
    sed '1d;$d' "$out/timing_gate.txt" | sed 's/^/  /'
    # Magic flags: every one must be an abstract-view artefact next to a macro (full GDS)
    # a MISSING metric (Magic not run, e.g. the flow stopped at LVS) stays empty, not 0
    v=$(awk -F'= ' '/Magic_violations = /{print $2+0}' "$out/check_openlane_run.txt")
    if [ -z "$v" ]; then fail "Magic_violations missing: Magic DRC did not run"
    elif [ "$v" = 0 ]; then pass "Magic_violations = 0"
    elif [ -n "$v" ] && "$KIT/tools/magic_macro_check.sh" "$RUNDIR" > "$out/magic_macro_check.txt" 2>&1; then
        pass "Magic: $v flags, all next to macros and clean on the full GDS (tools/magic_macro_check.sh)"
        tail -n 4 "$out/magic_macro_check.txt" | sed 's/^/    /'
    else
        fail "Magic: ${v:-no} flags not cleared by magic_macro_check.sh (see ${out#"$KIT"/}/magic_macro_check.txt)"
        tail -n 4 "$out/magic_macro_check.txt" 2>/dev/null | sed 's/^/    /'
    fi
    python3 "$KIT/tools/sta_corners.py" "$RUNDIR" > "$out/sta_corners.txt" 2>&1 \
        && pass "corners: ${out#"$KIT"/}/sta_corners.txt" || fail "tools/sta_corners.py"
    grep -E "^=====|worst|WNS|slack" "$out/sta_corners.txt" | head -n 24 | sed 's/^/    /'
    if DESIGN=GEMM_top SHELL_RUN=$(ip_shell_run) "$KIT/tools/power.sh" "$RUNDIR" > "$out/power.txt" 2>&1; then
        pass "power, vectorless: $(grep -E '^Total' "$RUNDIR/reports/power/vectorless.design.rpt" | awk '{print $5" W"}')"
    else fail "tools/power.sh (see ${out#"$KIT"/}/power.txt)"; fi
    NOTE="${RUNDIR##*/}, reports in ${out#"$KIT"/}"
    finish ip-check
}

st_ip_gls() {   # original testbench on the final IP netlist, rows + AXI macro gate-level, 3 shapes
    need ip-pre
    local run; run=$(ip_best_run)
    [ -f "$run/results/final/verilog/gl/GEMM_top.nl.v" ] || { echo "no final netlist in $run"; exit 1; }
    say "ip-gls: original testbench on ${run#"$OL"/} (rows + AXI macro gate-level)"
    local out=$HERE/logs/ip_gls_$STAMP shape tag t0 ref
    mkdir -p "$out"
    # reference: lean + clock gating RTL with the OpenRAM models (axi-sim, same shapes)
    local axl; axl=$(ls -td "$HERE"/logs/axi_sim_* 2>/dev/null | head -1)
    for shape in "" "8,32,544" "16,992,32"; do
        tag=${shape:+_M$(echo "$shape" | awk -F, '{print $1"K"$2"N"$3}')}
        t0=$(date +%s)
        if TB_SHAPE="$shape" BUILD="$KIT/sim/build_ip_gls$tag" SHELL_RUN=$(ip_shell_run) OL=$OL \
               "$KIT/sim/run_ip_gls.sh" "$run" "$REPO" > "$out/gls$tag.log" 2>&1; then
            pass "${shape:-64,64,64}: OVERALL PASS ($(( $(date +%s) - t0 )) s, $(wc -l < "$KIT/sim/build_ip_gls$tag/cycles_gls.txt") result events)"
        else fail "${shape:-64,64,64}: gate-level sim failed (see ${out#"$KIT"/}/gls$tag.log)"; tail -n 4 "$out/gls$tag.log" | sed 's/^/    /'; fi
        cp "$KIT/sim/build_ip_gls$tag/cycles_gls.txt" "$out/cycles_gls$tag.txt" 2>/dev/null
        ref=$axl/cycles_lean_cg-sram$tag.txt
        if [ -s "$ref" ] && diff -q "$ref" "$out/cycles_gls$tag.txt" > /dev/null 2>&1; then
            pass "${shape:-64,64,64}: same $(wc -l < "$ref") result events at the same cycles as the lean_cg RTL (axi-sim)"
        else fail "${shape:-64,64,64}: result events differ from ${ref#"$KIT"/}"; fi
    done
    NOTE="${run##*/}, logs in ${out#"$KIT"/}"
    finish ip-gls
}

# =========================================================================
case "${1:-}" in
    sim)   st_sim ;;
    pe)    st_pe ;;
    row)   st_row ;;
    array) st_array ;;
    array-check) need row; say "array-check: judge the existing array_v1 run (no OpenLane)"
                 RUNDIR=$OL/designs/gemm_array/runs/array_v1; array_verdict ;;
    core-sim)   st_core_sim ;;
    core-pre)   st_core_pre ;;
    core)       st_core ;;
    core-gls)   st_core_gls ;;
    core-triage) st_core_triage ;;
    core-status) st_core_status ;;
    core-probe) st_core_probe ;;
    core-route) st_core_route ;;
    core-precheck) st_core_precheck ;;
    core-check) need core-pre
                if [ -n "${TAG:-}" ]; then RUNDIR=$OL/designs/gemm_core/runs/$TAG; else RUNDIR=$(core_best_run); fi
                say "core-check: judge the existing run ${RUNDIR#"$OL"/} (no OpenLane)"; core_verdict ;;
    axi-sim)    st_axi_sim ;;
    axi-shell)  st_axi_shell ;;
    axi-gls)    st_axi_gls ;;
    ip-shell)   st_ip_shell ;;
    ip-pre)     st_ip_pre ;;
    ip)         st_ip ;;
    ip-route)   st_ip_route ;;
    ip-status)  st_ip_status ;;
    ip-check)   st_ip_check ;;
    ip-gls)     st_ip_gls ;;
    all)   "$0" sim && "$0" pe && "$0" row && "$0" array && "$0" core-sim && "$0" core-pre && "$0" core ;;
    status) cat "$LOG" ;;
    *) sed -n '2,/^# ----/p' "$0" | sed '$d'; exit 2 ;;
esac
