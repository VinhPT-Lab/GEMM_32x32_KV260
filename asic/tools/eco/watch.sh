#!/bin/bash
# Wait for container <name>; stop it and report on ERROR / disk under 10 GB.
name=$1; log=$2
sleep 5
while docker ps --format '{{.Names}}' | grep -qx "$name"; do
  if grep -qE "\[ERROR|^Error|Segmentation|Signal [0-9]|Killed" "$log" 2>/dev/null; then echo "WATCH: error in $log"; docker stop "$name" >/dev/null; break; fi
  a=$(df -BG --output=avail /home | tail -1 | tr -dc 0-9); if [ "$a" -lt 10 ]; then echo "WATCH: disk $a G"; docker stop "$name" >/dev/null; break; fi
  sleep 20
done
grep -E "^PROBE|\[ERROR|^Error|ANT-000|Found .* violations" "$log" | cut -c1-250
