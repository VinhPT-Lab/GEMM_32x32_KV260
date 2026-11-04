#!/bin/bash
# Report-only bound: STA of the final layout with standard cells at ss_100C_1v40 (1.80 V minus
# a 400 mV supply loss, far beyond the static IR estimate), top level (sta_ss140.tcl, RC nom and
# max) and register-to-register paths inside the row, the AXI shell and the PE (block_fmax.tcl).
IMG=ghcr.io/the-openroad-project/openlane:ff5509f65b17bfa4068d5336495ab1718987ff69-amd64
P=${ECO_DIR}; O=$P/paper/work/sta_ss140; mkdir -p $O
for RC in nom max; do
  docker run --rm --name stass14 -e DES=final -e C=ss14 -e RC=$RC -e ECO_ODB=$P/s5/final_a5/results/routing/GEMM_top.odb \
    -e ECO_SPEF_DIR=$P/s5/final_a5/results/routing/mca -v ${OL}:/openlane -v ~:~ \
    --user 1000:1000 --memory=10g --memory-swap=40g $IMG openroad -exit $P/paper/scripts/sta_ss140.tcl > $O/top_$RC.log 2>&1
  grep -E "^STA6B|\[ERROR|^Error" $O/top_$RC.log
done
for b in "ProcessingElementRow ${OL}/designs/gemm_row/runs/row_v1/results/final" \
         "GemmAxiShell ${OL}/designs/gemm_ip_shell/runs/ip_shell5/results/final" \
         "ProcessingElement ${OL}/designs/gemm_pe/runs/paper_pe/results/final"; do
  set -- $b
  for c in ss ss14; do
    docker run --rm --name stass14 -e FINAL=$2 -e DESIGN=$1 -e LIBCORNER=$c -e PDK_ROOT=${PDK_ROOT} -v ~:~ \
      --user 1000:1000 --memory=10g --memory-swap=40g $IMG sta -no_splash -exit $P/paper/scripts/block_fmax.tcl > $O/${1}_$c.rpt 2>&1
    grep -E "^FMAX|^Error" $O/${1}_$c.rpt
  done
done
echo STASS14_DONE
