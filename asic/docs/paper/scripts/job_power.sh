#!/bin/bash
# Activity-based power of one WHOLE job (job 2) of the final IP, split by phase: gate-level
# sim of the final netlist with a VCD of the whole job (vcd_job_ip.py, window c0+1..c1),
# per-phase activity (vcd2act_phases.py), OpenSTA report_power per phase at TT with the
# signoff SPEF (RC nom) and the final SDC (20 ns = 50 MHz), groups by block.
# The VCD is deleted once the activity files are written.
# usage: job_power.sh <M,K,N> <c0 = JOB_2_START - 1> <c1 = last RESULT_ACCEPT of job 2>
set -uo pipefail
P=${ECO_DIR}; K=${REPO}
IMG=ghcr.io/the-openroad-project/openlane:ff5509f65b17bfa4068d5336495ab1718987ff69-amd64
SHAPE=$1; C0=$2; C1=$3; tag=job_${SHAPE//,/x}
W=$P/paper/work/$tag; OUT=$P/paper/data/power/$tag; mkdir -p "$W" "$OUT"
ROW=${OL}/designs/gemm_row/runs/row_v1/results/final
SH=${OL}/designs/gemm_ip_shell/runs/ip_shell5
IPF=$P/s5/final_a5/results/final
python3 $P/paper/scripts/vcd_job_ip.py "$C0" "$C1" "$W/job.vcd" "$W/vcd_job.v" gl
t0=$(date +%s)
TB_SHAPE=$([ "$SHAPE" = 64,64,64 ] && echo "" || echo "$SHAPE") BUILD=$W EXTRA_V=$W/vcd_job.v SHELL_RUN=$SH \
  $K/sim/run_ip_gls.sh $P/s5/final_a5 ${KV260} > "$W/run.log" 2>&1
echo "JOBPOWER $tag sim $(( $(date +%s) - t0 )) s, $(grep -hoE 'VCD_(START|END) cycle=[0-9]+' $W/gls.log | tr '\n' ' ') vcd $(du -m $W/job.vcd | cut -f1) MB"
grep -q VCD_END "$W/gls.log" || { echo "JOBPOWER $tag: no VCD_END"; exit 1; }
grep -E "^(FAIL|ERROR)" "$W/gls.log" | head -3
rm -f "$W/gls.vvp" "$W"/*_gl.v
t0=$(date +%s)
python3 $P/paper/scripts/vcd2act_phases.py "$W/job.vcd" "$W/gls.log" $IPF/verilog/gl/GEMM_top.nl.v \
  $ROW/verilog/gl/ProcessingElementRow.nl.v $SH/results/final/verilog/gl/GemmAxiShell.nl.v "$OUT/$tag" \
  | sed "s/^/JOBPOWER $tag /"
echo "JOBPOWER $tag vcd2act $(( $(date +%s) - t0 )) s"
ls "$OUT/$tag.job.act" >/dev/null || exit 1
rm -f "$W/job.vcd"
ACTS=$(ls $OUT/$tag.*.act | tr '\n' ' ')
docker run --rm --name jobpower --memory=10g --memory-swap=40g -u 1000:1000 -v ~:~ \
  -e CORE_FINAL=$IPF -e ROW_FINAL=$ROW -e SHELL_FINAL=$SH/results/final -e DESIGN=GEMM_top -e PDK_ROOT=${PDK_ROOT} \
  -e OUT=$OUT/$tag -e ACTS="$ACTS" $IMG sta -no_splash -exit $P/paper/scripts/power_phases.tcl > $OUT/$tag.sta.log 2>&1
grep -E "^PHASEPOWER|^Error" $OUT/$tag.sta.log | sed "s/^/JOBPOWER $tag /"
for a in $ACTS; do
  o=${a%.act}
  python3 $K/tools/power/power_groups.py $o.inst.rpt $OUT/$tag.refs.txt > $o.groups.txt && rm -f $o.inst.rpt
  gzip -f $a
done
gzip -f $OUT/$tag.refs.txt
echo "JOBPOWER $tag done"
