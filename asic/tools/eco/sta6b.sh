#!/bin/bash
# sta6b.tcl for the source run (DES=v3r, needs V3R_ODB) and one ECO layout (DES=eco).
# usage: V3R_ODB=<ip_v3r round-1 odb> sta6b.sh <eco odb> <eco mca dir>
here=$(dirname "$0")
"$here/sta6b_one.sh" v3r "$1" "$2" && "$here/sta6b_one.sh" eco "$1" "$2"
