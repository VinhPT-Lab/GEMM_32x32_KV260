# ---------------------------------------------------------------------------
# grt_probe.tcl - OpenROAD script: global route only, on the post-CTS layout,
# with the same layer setup as OpenLane's resizer_routing_design.tcl, but
# with -allow_congestion and few (default 0) congestion iterations. It shows
# how congested the floorplan is and WHERE, in minutes, instead of dying in
# the rip-up/re-route iterations like core_v1 did (FastRoute in this OpenROAD
# indexes past the end of a buffer sized x_range+y_range in updateRouteType1
# once a detour gets longer than the die's half perimeter).
# Run by resume.tcl in probe mode. Env:
#   GEMM_PROBE_ITERS  congestion iterations (0: first routing only)
#   GEMM_PROBE_RPT    congestion report (bbox per overflowing gcell edge)
#   GEMM_PROBE_ODB    layout + congestion map, open in `openroad -gui` ->
#                     Heat Maps -> Routing Congestion
# ---------------------------------------------------------------------------
source $::env(SCRIPTS_DIR)/openroad/common/io.tcl
set read_args [list]
if { $::env(RSZ_MULTICORNER_LIB) } {
    lappend read_args -lib_fastest $::env(RSZ_LIB_FASTEST)
    lappend read_args -lib_slowest $::env(RSZ_LIB_SLOWEST)
}
lappend read_args -lib_typical $::env(RSZ_LIB)
read {*}$read_args
set_propagated_clock [all_clocks]

# routing obstructions (GRT_OBS: "layer x0 y0 x1 y1, ..." in um), as
# add_route_obs puts them in before global routing in a real run
if { [info exists ::env(GRT_OBS)] && [string trim $::env(GRT_OBS)] ne "" } {
    set gemm_block [ord::get_db_block]
    set gemm_tech [ord::get_db_tech]
    set gemm_dbu [$gemm_tech getDbUnitsPerMicron]
    set gemm_n 0
    foreach gemm_obs [split $::env(GRT_OBS) ","] {
        lassign [string trim $gemm_obs] l x0 y0 x1 y1
        odb::dbObstruction_create $gemm_block [$gemm_tech findLayer $l] \
            [expr {round($x0 * $gemm_dbu)}] [expr {round($y0 * $gemm_dbu)}] \
            [expr {round($x1 * $gemm_dbu)}] [expr {round($y1 * $gemm_dbu)}]
        incr gemm_n
    }
    puts "GEMM_PROBE: $gemm_n routing obstructions from GRT_OBS"
} else {
    puts "GEMM_PROBE: no routing obstructions"
}

source $::env(SCRIPTS_DIR)/openroad/common/set_routing_layers.tcl
source $::env(SCRIPTS_DIR)/openroad/common/set_layer_adjustments.tcl

set iters $::env(GEMM_PROBE_ITERS)
if { [catch { sta::check_positive_integer "-congestion_iterations" $iters }] } { set iters 1 }
puts "GEMM_PROBE: global_route with $iters congestion iterations, GRT_ADJUSTMENT $::env(GRT_ADJUSTMENT)"
global_route -congestion_iterations $iters -allow_congestion -verbose \
    -congestion_report_file $::env(GEMM_PROBE_RPT)
puts "GEMM_PROBE: global_route finished"

# the guide, for macro_cross.py (nets the global route left through a macro)
if { [info exists ::env(GEMM_PROBE_GUIDE)] && $::env(GEMM_PROBE_GUIDE) ne "" } {
    write_guides $::env(GEMM_PROBE_GUIDE)
    puts "GEMM_PROBE: wrote $::env(GEMM_PROBE_GUIDE)"
}

if { [info exists ::env(GEMM_PROBE_ODB)] && $::env(GEMM_PROBE_ODB) ne "" } {
    write_db $::env(GEMM_PROBE_ODB)
    puts "GEMM_PROBE: wrote $::env(GEMM_PROBE_ODB)"
}
puts "GEMM_PROBE_DONE"
