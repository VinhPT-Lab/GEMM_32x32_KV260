#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Row macro netlist vs RTL, random stimulus (sim/tb_row_equiv.v).
# LVS only proves layout = netlist; this checks netlist = RTL. It caught the
# resizer pin swap in row_v1 (PE 23, product bits 12-15), ~10 s.
#
# usage: sim/row_equiv.sh <ProcessingElementRow netlist .v / .nl.v> [cycles]
# Exit 0 and "ROW_EQUIV PASS" when every output bit matches.
# ---------------------------------------------------------------------------
set -euo pipefail
KIT=$(cd "$(dirname "$0")/.." && pwd)
NET=${1:?give the row netlist}
NCYC=${2:-2000}
BUILD=$KIT/sim/build_row_equiv
mkdir -p "$BUILD"
pdk_dir() {
    local r
    for r in "${PDK_ROOT:-}" "$HOME/.ciel" "$HOME/.volare"; do
        [ -n "$r" ] && [ -d "$r/${PDK:-sky130A}/libs.ref/sky130_fd_sc_hd/verilog" ] && { echo "$r/${PDK:-sky130A}"; return; }
    done
}
P=$(pdk_dir); [ -n "$P" ] || { echo "sky130A not found (set PDK_ROOT)"; exit 1; }
SC=$P/libs.ref/sky130_fd_sc_hd/verilog
# netlist with power pins (.v) needs USE_POWER_PINS; the .nl.v does not
PWR=(); grep -q "\.VPWR(" "$NET" && PWR=(-DUSE_POWER_PINS)
sed 's/^module ProcessingElementRow\b/module ProcessingElementRow_gl/' "$NET" > "$BUILD/row_gl.v"
iverilog -g2012 -DFUNCTIONAL -DUNIT_DELAY=#1 -DGEMM_DP_RESET=0 -DNCYC="$NCYC" "${PWR[@]}" -I "$KIT/rtl_asic" \
    -o "$BUILD/row_equiv.vvp" "$KIT/rtl_asic/gemm_asic_cfg.vh" "$KIT/sim/tb_row_equiv.v" \
    "$KIT/rtl_asic/PE_row.v" "$KIT/rtl_asic/PE.v" "$BUILD/row_gl.v" "$SC/primitives.v" "$SC/sky130_fd_sc_hd.v"
vvp -n "$BUILD/row_equiv.vvp" | grep -v '\$finish' | tee "$BUILD/row_equiv.log"
grep -q "ROW_EQUIV PASS" "$BUILD/row_equiv.log"
