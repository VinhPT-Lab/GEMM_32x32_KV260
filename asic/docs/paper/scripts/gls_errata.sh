#!/bin/bash
# Gate-level sim of the final IP netlist (sim/run_ip_gls.sh, unit delay) for the small errata
# cases, compared line by line with the RTL run of the same shape (sim/run_errata.sh builds):
# every testbench line about data and timing (FEATURE/WEIGHT/RESULT_ACCEPT, RESULT_VALID_FIRST,
# FAIL ..., the printed result matrices, Mismatch / Protocol / beat counts). SRAM collision
# warnings are left out (their text has the instance path).
# usage: gls_errata.sh <M,K,N>...
P=${ECO_DIR}; K=${REPO}
SH=${OL}/designs/gemm_ip_shell/runs/ip_shell5
filt() { grep -vE "WARNING|^Testbench|^DUT|^\s*$|VCD_|FSM_STATE" "$1" | grep -E "ACCEPT|RESULT_VALID_FIRST|^FAIL|^-?[0-9]+( -?[0-9]+)*$|MATRIX|Mismatch count|Protocol error|accepted beats|AXIL_|JOB_[0-9]_(START|END)|OVERALL"; }
for s in "$@"; do
  IFS=, read -r M Kd N <<< "$s"; tag=M${M}K${Kd}N${N}
  W=$P/paper/work/errata/gls_$tag; mkdir -p "$W"
  t0=$(date +%s)
  TB_SHAPE=$s BUILD=$W SHELL_RUN=$SH $K/sim/run_ip_gls.sh $P/s5/final_a5 ${KV260} > "$W/run.log" 2>&1
  rm -f "$W/gls.vvp" "$W"/*_gl.v
  R=$K/sim/build_system_asic-sram_axileancg_$tag/system.log
  filt "$W/gls.log" > "$W/gls.filt"; filt "$R" > "$W/rtl.filt"
  if cmp -s "$W/gls.filt" "$W/rtl.filt"; then same=IDENTICAL; else same="DIFFERENT ($(diff "$W/gls.filt" "$W/rtl.filt" | grep -c '^[<>]') lines)"; fi
  echo "GLSERRATA $s sim $(( $(date +%s) - t0 )) s, compared lines $(wc -l < "$W/gls.filt"), GLS vs RTL: $same, FAIL lines GLS $(grep -c '^FAIL' "$W/gls.filt") RTL $(grep -c '^FAIL' "$W/rtl.filt"), $(grep -m1 -o 'OVERALL [A-Z]*' "$W/gls.log")"
done
