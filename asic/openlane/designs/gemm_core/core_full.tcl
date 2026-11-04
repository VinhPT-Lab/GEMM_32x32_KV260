# ---------------------------------------------------------------------------
# core_full.tcl - the whole gemm_core flow in OpenLane's interactive mode:
# the steps of flow.tcl (OpenLane 1.0.2 run_non_interactive_mode) up to and
# including CTS, then route_signoff.tcl - the same routing + signoff as
# core-route (resume.tcl), with its guards: detailed-router seeds, antenna
# ECO rounds, no LVS on a layout with shorts.
# Started by run_flow.sh (core):
#   make -C $OL quick_run QUICK_RUN_DESIGN="gemm_core -it -file designs/gemm_core/core_full.tcl"
# full_params.tcl next to this file (written by run_flow.sh) sets GEMM_NEW_TAG.
# ---------------------------------------------------------------------------
package require openlane

set here [file dirname [file normalize [info script]]]
source $here/full_params.tcl
if { ![info exists GEMM_NEW_TAG] } { puts stderr "\[ERROR\]: full_params.tcl does not set GEMM_NEW_TAG"; exit 1 }

prep -design gemm_core -tag $GEMM_NEW_TAG -overwrite
puts_info "gemm: full run $GEMM_NEW_TAG (synthesis .. CTS, then route_signoff.tcl)"

# flow.tcl: verilator_lint_check, synthesis, floorplan, placement, cts
# (run_cts_step = run_cts + run_resizer_timing)
if { $::env(RUN_LINTER) } { run_verilator }
run_synthesis
run_floorplan
run_placement
run_cts
run_resizer_timing
save_state "After CTS"

source $here/route_signoff.tcl
