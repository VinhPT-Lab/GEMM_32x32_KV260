# ---------------------------------------------------------------------------
# ip_timing_eco.tcl - setup repair after a global route of gemm_ip,
# with the antenna diodes of that global route already in the design.
# Run by gemm_ip_timing_eco in ip_route_signoff.tcl (OpenROAD, run_openroad_script),
# which also restores the views from before this step if OpenROAD fails.
#
# Why: GRT_REPAIR_ANTENNAS puts its diodes in global_routing, after the last
# resizer step, and nothing re-times the design afterwards. ip_v2: 22 diodes
# on _10437_ (0.27 pF) behind an o21ai_1, 3.7 ns on one gate, Typical setup
# -2.00 ns on 8 endpoints (o_result_data of quantize lane 0); OpenSTA with that
# one cell as o21ai_4 gives -0.21 ns.
#
# Steps as OpenLane's resizer_routing_timing.tcl (global route, parasitics from
# it, repair_timing, detailed placement, check_placement), except:
#   - repair_timing only if a cell -> cell path (standard cells at both ends,
#     no port, no macro pin) has negative setup slack;
#   - -skip_pin_swap on every repair_timing (as the patched OpenLane scripts);
#   - Typical library only (see the read below);
#   - no hold repair: hold stays as fixed after CTS, timing_gate.py checks it
#     on every corner (a test on the placed DB of ip_pre hung the machine,
#     memory suspected, inside repair_timing -hold: 55329 endpoints, ~4800 buffers);
#   - repair_design only with GEMM_IP_TIMING_ECO_DESIGN 1 (default 0);
#   - "gemm_timing_eco: changed N" (cells resized, added or removed) tells
#     ip_route_signoff.tcl whether to route globally again;
#   - run time and peak memory of this OpenROAD process at the end of the log.
# The repair re-routes the nets it changed incrementally in memory (GRT-0009),
# the code that died with SIGSEGV in core layout v3 (gemm_core/config.tcl,
# GLB_RESIZER_TIMING_OPTIMIZATIONS); those routes are not written, the caller
# runs a fresh global route.
# Settings (defaults in brackets):
#   GEMM_IP_TIMING_ECO_SETUP_MARGIN  [GLB_RESIZER_SETUP_SLACK_MARGIN]
#   GEMM_IP_TIMING_ECO_MAX_BUFFER_PERCENT [5]
#   GEMM_IP_TIMING_ECO_DESIGN        [0]
# ---------------------------------------------------------------------------
set eco_t0 [clock seconds]
source $::env(SCRIPTS_DIR)/openroad/common/io.tcl
# Typical library only, even with RSZ_MULTICORNER_LIB: with all three corners
# the worst slack and repair_timing follow the Slowest corner (ip_v2: -11 ns),
# and the slow corner is not touched without a separate decision
read -no_spefs -lib_typical $::env(RSZ_LIB)

proc eco_env {name default} {
    return [expr {[info exists ::env($name)] ? $::env($name) : $default}]
}
set setup_margin [eco_env GEMM_IP_TIMING_ECO_SETUP_MARGIN $::env(GLB_RESIZER_SETUP_SLACK_MARGIN)]
set max_buf      [eco_env GEMM_IP_TIMING_ECO_MAX_BUFFER_PERCENT 5]
set do_design    [eco_env GEMM_IP_TIMING_ECO_DESIGN 0]

set_propagated_clock [all_clocks]
source $::env(SCRIPTS_DIR)/openroad/common/resizer.tcl
set_dont_touch_wrapper
if { [info exists ::env(DONT_USE_CELLS)] } {
    set_dont_use $::env(DONT_USE_CELLS)
}
source $::env(SCRIPTS_DIR)/openroad/common/set_routing_layers.tcl
source $::env(SCRIPTS_DIR)/openroad/common/set_layer_adjustments.tcl

# the routes of the global route that just ran are not in the database
set arg_list [list -congestion_iterations $::env(GRT_OVERFLOW_ITERS) -verbose]
lappend arg_list -congestion_report_file $::env(GRT_CONGESTION_REPORT_FILE)
if { $::env(GRT_ALLOW_CONGESTION) == 1 } {
    lappend arg_list -allow_congestion
}
global_route {*}$arg_list
source $::env(SCRIPTS_DIR)/openroad/common/set_rc.tcl
estimate_parasitics -global_routing

# worst setup slack (s) of the cell -> cell paths (a standard cell at both ends,
# no port, no macro pin), "" if none is negative, and their count. Paths to and
# from macro pins (SRAM, rows, AXI) are left alone: ip_v3 had 2350 of them at
# -2.8 ns (AXI output across the die, SRAM read-add-write in half a cycle),
# which repair_timing cannot fix (-0.03 ns for 5 cells).
proc eco_is_cell {pin} {
    if { [string first "/" $pin] < 0 } { return 0 }
    set p [sta::find_pin $pin]
    if { $p eq "NULL" || $p eq "" } { return 0 }
    set ref [get_property [$p instance] ref_name]
    if { ![info exists ::eco_cell($ref)] } {
        set m [[ord::get_db] findMaster $ref]
        set ::eco_cell($ref) [expr {$m ne "NULL" && ![$m isBlock]}]
    }
    return $::eco_cell($ref)
}
proc eco_internal_setup {} {
    set worst ""
    set n 0
    foreach pe [find_timing_paths -path_delay max -group_count 200000 -endpoint_count 1 -sort_by_slack -slack_max 0] {
        set e [get_full_name [get_property $pe endpoint]]
        set s [get_full_name [get_property $pe startpoint]]
        if { ![eco_is_cell $e] || ![eco_is_cell $s] } { continue }
        set sl [$pe slack]
        if { $sl >= 0 } { continue }
        incr n
        if { $worst eq "" || $sl < $worst } { set worst $sl }
    }
    return [list $worst $n]
}
proc eco_masters {} {
    set m [dict create]
    foreach inst [[ord::get_db_block] getInsts] {
        dict set m [$inst getName] [[$inst getMaster] getName]
    }
    return $m
}
proc eco_report {tag} {
    set i [eco_internal_setup]
    set iw [expr {[lindex $i 0] eq "" ? "none negative" : "[format %.3f [expr {[lindex $i 0] * 1e9}]] ns on [lindex $i 1] endpoint(s)"}]
    puts "gemm_timing_eco: $tag: cell->cell setup $iw;\
          all setup wns [format %.3f [expr {[sta::worst_slack_cmd max] * 1e9}]]\
          tns [format %.3f [expr {[sta::total_negative_slack_cmd max] * 1e9}]],\
          hold wns [format %.3f [expr {[sta::worst_slack_cmd min] * 1e9}]] (ns, Typical, global-route parasitics)"
    return [lindex $i 0]
}

set before [eco_masters]
set iw [eco_report "before"]
if { $iw eq "" || $iw >= 0 } {
    puts "gemm_timing_eco: no negative cell->cell setup slack - repair skipped"
} else {
    if { $do_design } {
        repair_design
        eco_report "after repair_design"
    }
    repair_timing -setup -skip_pin_swap -setup_margin $setup_margin -max_buffer_percent $max_buf
    eco_report "after repair_timing -setup"
}

set after [eco_masters]
set resized 0
set added 0
dict for {name master} $after {
    if { ![dict exists $before $name] } {
        incr added
    } elseif { [dict get $before $name] ne $master } {
        incr resized
    }
}
set removed [expr {[dict size $before] + $added - [dict size $after]}]
puts "gemm_timing_eco: changed [expr {$resized + $added + $removed}] ($resized resized, $added added, $removed removed)"

source $::env(SCRIPTS_DIR)/openroad/common/dpl_cell_pad.tcl
detailed_placement
if { $::env(GLB_OPTIMIZE_MIRRORING) } {
    optimize_mirroring
}
if { [catch {check_placement -verbose} errmsg] } {
    puts stderr $errmsg
    exit 1
}
unset_dont_touch_wrapper
write

set hwm "?"
catch { set hwm [lindex [exec grep VmHWM /proc/[pid]/status] 1] }
puts "gemm_timing_eco: runtime [expr {[clock seconds] - $eco_t0}] s, peak memory [expr {$hwm eq "?" ? "?" : $hwm / 1024}] MB"
