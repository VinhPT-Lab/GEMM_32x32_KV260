#!/bin/bash
# Run one long job and watch it until it ends: every minute check the disk (stop under
# 10 GB) and the log (stop on [ERROR], segfault, Killed, Traceback). Ends only when the
# job ends or is stopped, and prints one summary (PROBE lines and the reason).
# usage: runjob.sh <container name[,name...]> <log> <command ...>
#   the command must start a docker container named <container name> (nor.sh, ol.sh...)
#   or be a script that does; the log is the file the job writes.
source "$(dirname "$0")/env.sh"
name=$1; log=$2; shift 2
systemd-inhibit --what=sleep:idle "$@" > "$log.runjob" 2>&1 &
pid=$!
why=done
while kill -0 $pid 2>/dev/null; do
  sleep 60
  if grep -qE "\[ERROR|^Error|Segmentation|segfault|Signal 11|Killed|Traceback" "$log" "$log.runjob" 2>/dev/null; then
    why=error; for n in ${name//,/ }; do docker stop "$n" >/dev/null 2>&1; done; break
  fi
  a=$(df -BG --output=avail "$ECO_DIR" | tail -1 | tr -dc 0-9)
  if [ "$a" -lt 10 ]; then why="disk ${a}G"; for n in ${name//,/ }; do docker stop "$n" >/dev/null 2>&1; done; break; fi
done
wait $pid; rc=$?
grep -hE "^PROBE|^STA6B|probe:|\[ERROR|^Error|Traceback|Number of violations = |ANT-000" "$log" "$log.runjob" 2>/dev/null | tail -40 | cut -c1-300
echo "RUNJOB $name: $why, exit $rc, disk $(df -BG --output=avail "$ECO_DIR" | tail -1 | tr -d ' ')"
