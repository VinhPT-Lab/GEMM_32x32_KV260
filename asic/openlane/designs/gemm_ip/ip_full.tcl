# ---------------------------------------------------------------------------
# ip_full.tcl - the whole gemm_ip flow in OpenLane's interactive mode, step for
# step gemm_core/core_full.tcl with the design gemm_ip: flow.tcl up to and
# including CTS, then ip_route_signoff.tcl (gemm_core/route_signoff.tcl copied
# for gemm_ip: router seeds, antenna ECO rounds, timing ECO after each global
# route, no LVS on a layout with shorts). It finds ant_eco.py /
# macro_cross.py in DESIGN_DIR (run_flow.sh copies them next to this file).
# Started by run_flow.sh (ip):
#   make -C $OL quick_run QUICK_RUN_DESIGN="gemm_ip -it -file designs/gemm_ip/ip_full.tcl"
# full_params.tcl next to this file (written by run_flow.sh) sets GEMM_NEW_TAG.
# ---------------------------------------------------------------------------
package require openlane

set here [file dirname [file normalize [info script]]]
source $here/full_params.tcl
if { ![info exists GEMM_NEW_TAG] } { puts stderr "\[ERROR\]: full_params.tcl does not set GEMM_NEW_TAG"; exit 1 }

prep -design gemm_ip -tag $GEMM_NEW_TAG -overwrite
puts_info "gemm: full run $GEMM_NEW_TAG (synthesis .. CTS, then ip_route_signoff.tcl)"

if { $::env(RUN_LINTER) } { run_verilator }
run_synthesis
run_floorplan
run_placement
run_cts
run_resizer_timing
save_state "After CTS"

source $here/ip_route_signoff.tcl
