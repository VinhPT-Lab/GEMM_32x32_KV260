#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# core_watch.sh [tag] - watch an OpenLane core run live.
#
# Shows the log of the step that is running right now and jumps to the next
# step's log by itself (synthesis, placement, CTS, global route, detailed
# route, signoff ...). Ctrl+C only stops the watching; the run keeps going.
# It only reads files, so it is safe while a run is going.
#
#   bash tools/core_watch.sh            the last core run (state/core_last_tag.txt, else core_v4)
#   bash tools/core_watch.sh core_v4r   another run
# Env: OL [$HOME/OpenLane], KIT [the kit this script is in, else $HOME/gemm_asic_kit]
# ---------------------------------------------------------------------------
OL=${OL:-$HOME/OpenLane}
here=$(cd "$(dirname "$0")/.." 2>/dev/null && pwd)
if [ -n "${KIT:-}" ]; then :; elif [ -f "$here/openlane/run_flow.sh" ]; then KIT=$here; else KIT=$HOME/gemm_asic_kit; fi
tag=${1:-${TAG:-$(cat "$KIT/openlane/state/core_last_tag.txt" 2>/dev/null)}}
tag=${tag:-core_v4}
run=$OL/designs/gemm_core/runs/$tag

cur=""; tp=""; ended=""
stop() { [ -n "$tp" ] && kill "$tp" 2>/dev/null; printf '\n(stopped watching - the run itself is still going)\n'; exit 0; }
trap stop INT TERM

printf 'watching %s\nCtrl+C = stop watching (the run keeps going)\n' "$run"
[ -d "$run" ] || echo "(no run directory yet - waiting for OpenLane to create it)"
while :; do
    new=$(ls -t "$run"/logs/*/*.log 2>/dev/null | head -1)
    if [ -n "$new" ] && [ "$new" != "$cur" ]; then
        [ -n "$tp" ] && kill "$tp" 2>/dev/null
        cur=$new
        what=$(grep -hE '^\[INFO\]: (Running|Starting)' "$run/openlane.log" 2>/dev/null | tail -1 \
               | sed -E 's/^\[INFO\]: //; s/ \(log: .*//; s/\.\.\.$//')
        printf '\n\033[1m===== %s  %s  %s\033[0m\n' "$(date +%H:%M)" "${cur#"$run"/}" "${what:+- $what}"
        tail -n 15 -F "$cur" 2>/dev/null &
        tp=$!
        ended=""
    fi
    if [ -z "$ended" ]; then
        end=$(grep -hE 'Flow complete|Flow failed' "$run/openlane.log" 2>/dev/null | tail -1)
        if [ -n "$end" ]; then
            sleep 2
            printf '\n\033[1m===== %s  OpenLane: %s\033[0m\n' "$(date +%H:%M)" "$end"
            printf '(run_flow.sh now checks the results; see its output, or: openlane/run_flow.sh core-status)\n'
            ended=1
        fi
    fi
    sleep 3
done
