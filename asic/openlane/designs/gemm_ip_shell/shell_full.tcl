# ---------------------------------------------------------------------------
# shell_full.tcl - the whole gemm_ip_shell flow in OpenLane's interactive mode:
# the steps of flow.tcl up to and including CTS (as gemm_core/core_full.tcl),
# then gemm_core/route_signoff.tcl - the core's routing + signoff with its
# guards (router seeds, antenna ECO rounds, no LVS on a layout with shorts).
# route_signoff.tcl finds ant_eco.py / macro_cross.py in DESIGN_DIR, the seed
# hook below ant_seed.py
# (run_flow.sh ip-shell copies them next to this file in $OL).
# Started by run_flow.sh (ip-shell):
#   make -C $OL quick_run QUICK_RUN_DESIGN="gemm_ip_shell -it -file designs/gemm_ip_shell/shell_full.tcl"
# full_params.tcl next to this file (written by run_flow.sh) sets GEMM_NEW_TAG.
# ---------------------------------------------------------------------------
package require openlane

set here [file dirname [file normalize [info script]]]
source $here/full_params.tcl
if { ![info exists GEMM_NEW_TAG] } { puts stderr "\[ERROR\]: full_params.tcl does not set GEMM_NEW_TAG"; exit 1 }

prep -design gemm_ip_shell -tag $GEMM_NEW_TAG -overwrite
puts_info "gemm: full run $GEMM_NEW_TAG (synthesis .. CTS, then gemm_core/route_signoff.tcl)"

if { $::env(RUN_LINTER) } { run_verilator }
run_synthesis
run_floorplan
run_placement
run_cts
run_resizer_timing
save_state "After CTS"

# Antenna seed: route_signoff.tcl calls add_route_obs right after the port and
# heuristic diodes, then reads GEMM_ANT_ECO_RPT as the violator list to put ECO
# diodes for before routing round 0. ant_seed.py writes that list from the
# database at that point (gates on input-port nets or far from their driver,
# see its header), so the diodes go next to those gates before the first route.
rename add_route_obs gemm_shell_add_route_obs
proc add_route_obs {args} {
    gemm_shell_add_route_obs
    increment_index
    set log [index_file $::env(routing_logs)/ant_seed.log]
    set rpt $::env(routing_tmpfiles)/ant_seed.rpt
    puts_info "gemm: antenna seed list (log: [relpath . $log])"
    if { [catch {exec openroad -exit -no_splash -python $::env(DESIGN_DIR)/ant_seed.py $::env(CURRENT_ODB) \
                     --out $rpt --min-dist $::env(GEMM_ANT_SEED_DIST) >& $log} e] || ![file exists $rpt] } {
        puts_warn "gemm: ant_seed.py failed ($e) - routing without the seeded diodes"
        return
    }
    set ::env(GEMM_ANT_ECO_RPT) $rpt
}

source $here/../gemm_core/route_signoff.tcl
