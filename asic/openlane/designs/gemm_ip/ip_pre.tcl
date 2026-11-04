# ---------------------------------------------------------------------------
# ip_pre.tcl - first part of the gemm_ip flow, to judge the floorplan before the
# ~10 h run: lint, synthesis, floorplan (macro placement + PDN), placement
# (global placement, resizer, detailed placement), then the global route with
# the settings of the real run (route obstructions, congestion iterations,
# antenna repair) and the macro-crossing check of route_signoff.tcl
# (gemm_core/macro_cross.py). No CTS: overflow here is before the clock tree.
# Started by run_flow.sh ip-pre:
#   make -C $OL quick_run QUICK_RUN_DESIGN="gemm_ip -it -file designs/gemm_ip/ip_pre.tcl"
# ---------------------------------------------------------------------------
package require openlane
prep -design gemm_ip -tag ip_pre -overwrite
run_verilator
run_synthesis
run_floorplan
puts "\[INFO\]: GEMM_IP_FLOORPLAN_DONE"
run_placement
puts "\[INFO\]: GEMM_IP_PLACEMENT_DONE"
add_route_obs
global_routing
set rpt $::env(routing_reports)/macro_cross.rpt
set rc 0
if { [catch { exec python3 $::env(DESIGN_DIR)/macro_cross.py --guide $::env(CURRENT_GUIDE) \
                  --def $::env(CURRENT_DEF) --lef $::env(MERGED_LEF) \
                  --grt-obs [expr {[info exists ::env(GRT_OBS)] ? $::env(GRT_OBS) : ""}] \
                  --report $rpt } out opts] } {
    set rc [lindex [dict get $opts -errorcode] 2]
}
puts $out
puts "\[INFO\]: GEMM_IP_MACRO_CROSS exit $rc"
save_state "After global routing (ip_pre)"
puts "\[INFO\]: GEMM_IP_PRE_DONE"
