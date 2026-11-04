#!/bin/bash
# Leakage per block (top-level cells + SRAM, one row, AXI shell) at tt / ff / ss, each block
# run on its own netlist + SPEF (leak_blocks.tcl), then summed by leak_blocks.py.
P=${ECO_DIR}
IMG=ghcr.io/the-openroad-project/openlane:ff5509f65b17bfa4068d5336495ab1718987ff69-amd64
O=$P/paper/data/power/leak_blocks; mkdir -p $O
for c in tt ff ss; do for b in row axi top; do
  docker run --rm --name leakblocks --memory=10g --memory-swap=40g -u 1000:1000 -v ~:~ \
    -e CORE_FINAL=$P/s5/final_a5/results/final -e ROW_FINAL=${OL}/designs/gemm_row/runs/row_v1/results/final \
    -e SHELL_FINAL=${OL}/designs/gemm_ip_shell/runs/ip_shell5/results/final -e MACRO_LIB=$P/lib \
    -e PDK_ROOT=${PDK_ROOT} -e LIBCORNER=$c -e BLOCK=$b -e OUT=$O/${b}_$c $IMG \
    sta -no_splash -exit $P/paper/scripts/leak_blocks.tcl > $O/${b}_$c.log 2>&1
  grep -hE "^LEAKBLOCK|^Error" $O/${b}_$c.log
done; done
python3 $P/paper/scripts/leak_blocks.py $O $P/paper/data/leakage_by_block_3corners.csv && gzip -f $O/*.inst.rpt $O/*.refs.txt
