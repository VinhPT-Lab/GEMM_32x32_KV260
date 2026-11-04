#!/usr/bin/env bash
# RightShifter against the original: simulation over all shift amounts (iverilog),
# and, if docker and the OpenLane image are there, a formal proof with yosys.
set -uo pipefail
KIT=$(cd "$(dirname "$0")/.." && pwd)
B=$KIT/sim/build_rs_equiv; mkdir -p "$B"
iverilog -g2012 -o "$B/rs.vvp" "$KIT/sim/tb_right_shifter_equiv.v" "$KIT/sim/Right_shifter_ref.v" "$KIT/rtl_asic/Right_shifter.v" \
    && vvp -n "$B/rs.vvp" | tee "$B/sim.log" | grep -E "RS_EQUIV|MISMATCH"
IMG=${OL_IMAGE:-ghcr.io/the-openroad-project/openlane:ff5509f65b17bfa4068d5336495ab1718987ff69-amd64}
if command -v docker >/dev/null && docker image inspect "$IMG" >/dev/null 2>&1; then
    cat > "$B/rs_equiv.ys" <<'YS'
read_verilog -sv /k/sim/Right_shifter_ref.v
read_verilog -sv /k/rtl_asic/Right_shifter.v
chparam -set P_SHIFT_WIDTH 10 RightShifter_ref RightShifter
prep
miter -equiv -flatten -make_assert RightShifter_ref RightShifter miter
hierarchy -top miter
sat -verify -prove-asserts miter
YS
    if docker run --rm -v "$KIT:/k" "$IMG" yosys -q -s /k/sim/build_rs_equiv/rs_equiv.ys > "$B/formal.log" 2>&1; then
        echo "RS_FORMAL PASS (yosys proved the two modules equal for every input)"
    else
        echo "RS_FORMAL FAIL - see $B/formal.log"; tail -20 "$B/formal.log"
    fi
else
    echo "(no docker image $IMG here - formal check skipped)"
fi
