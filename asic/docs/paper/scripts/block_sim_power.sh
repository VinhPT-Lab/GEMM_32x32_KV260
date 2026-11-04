#!/bin/bash
# Random-data gate-level simulation of one hardened block (pe | row) against its RTL,
# VCD window -> activity (tools/power/vcd2act_flat.py) -> power at TT with the block's
# signoff SPEF, clock re-created at PERIOD ns (default 20 = 50 MHz). VCD deleted after.
# usage: block_sim_power.sh <pe|row> <run dir>     env: W0 WN NCYC PERIOD
set -uo pipefail
P=${ECO_DIR}; K=${REPO}
IMG=ghcr.io/the-openroad-project/openlane:ff5509f65b17bfa4068d5336495ab1718987ff69-amd64
B=$1; RUN=$2; W0=${W0:-200}; WN=${WN:-1000}; NCYC=${NCYC:-$((W0 + WN + 100))}; PERIOD=${PERIOD:-20}
SC=${PDK_ROOT}/sky130A/libs.ref/sky130_fd_sc_hd/verilog
if [ "$B" = row ]; then D=ProcessingElementRow; COLS=32; DEF=-DROW; else D=ProcessingElement; COLS=1; DEF=; fi
Wd=$P/paper/work/block_$B; OUT=$P/paper/data/power/block_$B; mkdir -p "$Wd" "$(dirname $OUT)"
# RTL reference with ref_ module names
sed -e 's/\bmodule ProcessingElementRow\b/module ref_ProcessingElementRow/' -e 's/\bmodule ProcessingElement\b/module ref_ProcessingElement/' \
    -e 's/^\(\s*\)ProcessingElement\b/\1ref_ProcessingElement/' $K/rtl_asic/PE.v $K/rtl_asic/PE_row.v > "$Wd/ref.v"
python3 - "$RUN/results/final/verilog/gl/$D.nl.v" "$Wd/dut_gl.v" <<'PY'
import re, sys
s = open(sys.argv[1]).read()
s = re.sub(r"^\s*sky130_\w+__(?:decap|fill|tapvpwrvgnd|diode)\w*\s+[^\s(]+\s*\(.*?\);\s*$\n?", "", s, flags=re.M | re.S)
open(sys.argv[2], "w").write(s)
PY
cd "$Wd"
iverilog -g2012 -DFUNCTIONAL -DUNIT_DELAY=#1 $DEF -I $K/rtl_asic -P tb_block_rand.COLS=$COLS -P tb_block_rand.W0=$W0 -P tb_block_rand.WN=$WN \
  -P tb_block_rand.NCYC=$NCYC -o sim.vvp $P/paper/sim/tb_block_rand.v dut_gl.v ref.v $SC/primitives.v $SC/sky130_fd_sc_hd.v > comp.log 2>&1 \
  || { echo "BLOCKPOWER $B compile failed"; tail -5 comp.log; exit 1; }
t0=$(date +%s); vvp -n sim.vvp > sim.log 2>&1
echo "BLOCKPOWER $B sim $(( $(date +%s) - t0 )) s: $(grep -hE 'BLOCK_RAND' sim.log) vcd $(du -m win.vcd | cut -f1) MB"
grep -q "PASS" sim.log || { echo "BLOCKPOWER $B: simulation mismatch"; exit 1; }
python3 $K/tools/power/vcd2act_flat.py win.vcd dut_gl.v dut $OUT.act | sed "s/^/BLOCKPOWER $B /"
rm -f win.vcd sim.vvp
docker run --rm --name blockpower --memory=10g --memory-swap=40g -u 1000:1000 -v ~:~ \
  -e FINAL=$RUN/results/final -e DESIGN=$D -e PDK_ROOT=${PDK_ROOT} -e OUT=$OUT -e ACT=$OUT.act -e PERIOD=$PERIOD \
  $IMG sta -no_splash -exit $P/paper/scripts/block_power.tcl > $OUT.log 2>&1
grep -E "activity from|clock period|^Total|^Error" $OUT.log | sed "s/^/BLOCKPOWER $B /"
