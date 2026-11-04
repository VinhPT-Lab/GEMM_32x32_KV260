#!/bin/bash
# SUPERSEDED: keeps only the last name of each VCD id, so nets on the row / AXI boundary get no
# activity (see data/superseded_alias_bug/README.txt); use vcd2act_phases.py / job_power.sh.
# Activity-based power of the final IP for one matrix shape: gate-level sim of the final
# netlist with a VCD window [C0, C1) taken while the array computes, VCD -> activity per
# driver pin, OpenSTA report_power at TT with the signoff SPEF (RC nom) and the final SDC
# (20 ns = 50 MHz), groups by block. The VCD is deleted once the activity file is written.
# usage: vcd_power.sh <M,K,N> <C0> <C1>
set -uo pipefail
P=${ECO_DIR}; K=${REPO}
IMG=ghcr.io/the-openroad-project/openlane:ff5509f65b17bfa4068d5336495ab1718987ff69-amd64
SHAPE=$1; C0=$2; C1=$3; tag=${SHAPE//,/x}_${C0}_$C1
W=$P/paper/work/vcd_$tag; OUT=$P/paper/data/power; mkdir -p "$W" "$OUT"
ROW=${OL}/designs/gemm_row/runs/row_v1/results/final
SH=${OL}/designs/gemm_ip_shell/runs/ip_shell5
IPF=$P/s5/final_a5/results/final
python3 $P/paper/scripts/vcd_window_ip.py "$C0" "$C1" "$W/win.vcd" "$W/vcd_window.v"
t0=$(date +%s)
TB_SHAPE=$([ "$SHAPE" = 64,64,64 ] && echo "" || echo "$SHAPE") BUILD=$W EXTRA_V=$W/vcd_window.v SHELL_RUN=$SH \
  $K/sim/run_ip_gls.sh $P/s5/final_a5 ${KV260} > "$W/run.log" 2>&1
echo "VCDPOWER $tag sim $(( $(date +%s) - t0 )) s, $(grep -hoE 'VCD_(START|END) cycle=[0-9]+' $W/gls.log | tr '\n' ' ') vcd $(du -m $W/win.vcd | cut -f1) MB"
grep -q VCD_END "$W/gls.log" || { echo "VCDPOWER $tag: no VCD_END"; exit 1; }
python3 $P/paper/scripts/vcd2act_ip.py "$W/win.vcd" $IPF/verilog/gl/GEMM_top.nl.v $ROW/verilog/gl/ProcessingElementRow.nl.v \
  $SH/results/final/verilog/gl/GemmAxiShell.nl.v "$OUT/vcd_$tag.act" | sed "s/^/VCDPOWER $tag /"
rm -f "$W/win.vcd" "$W/gls.vvp" "$W"/*_gl.v
docker run --rm --name vcdpower --memory=10g --memory-swap=40g -u 1000:1000 -v ~:~ \
  -e CORE_FINAL=$IPF -e ROW_FINAL=$ROW -e SHELL_FINAL=$SH/results/final -e DESIGN=GEMM_top -e PDK_ROOT=${PDK_ROOT} \
  -e OUT=$OUT/vcd_$tag -e ACT=$OUT/vcd_$tag.act $IMG sta -no_splash -exit $K/tools/power/power.tcl > $OUT/vcd_$tag.log 2>&1
grep -E "activity from|^Total|^Error" $OUT/vcd_$tag.log | sed "s/^/VCDPOWER $tag /"
python3 $K/tools/power/power_groups.py $OUT/vcd_$tag.inst.rpt $OUT/vcd_$tag.refs.txt > $OUT/vcd_$tag.groups.txt
tail -1 $OUT/vcd_$tag.groups.txt | sed "s/^/VCDPOWER $tag /"
