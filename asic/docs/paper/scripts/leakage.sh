#!/bin/bash
# Leakage of the final IP at the tt / ff / ss standard-cell corners (SRAM: TT lib only).
P=${ECO_DIR}; K=${REPO}
IMG=ghcr.io/the-openroad-project/openlane:ff5509f65b17bfa4068d5336495ab1718987ff69-amd64
O=$P/paper/data/power; mkdir -p $O
for c in tt ff ss; do
  docker run --rm --name leakage --memory=10g --memory-swap=40g -u 1000:1000 -v ~:~ \
    -e CORE_FINAL=$P/s5/final_a5/results/final -e ROW_FINAL=${OL}/designs/gemm_row/runs/row_v1/results/final \
    -e SHELL_FINAL=${OL}/designs/gemm_ip_shell/runs/ip_shell5/results/final -e DESIGN=GEMM_top \
    -e PDK_ROOT=${PDK_ROOT} -e LIBCORNER=$c -e OUT=$O/leak_$c $IMG sta -no_splash -exit $P/paper/scripts/leakage.tcl > $O/leak_$c.log 2>&1
  python3 $K/tools/power/power_groups.py $O/leak_$c.inst.rpt $O/leak_$c.refs.txt > $O/leak_$c.groups.txt
  echo "LEAK $c $(grep -E '^Total' $O/leak_$c.design.rpt)"
done
