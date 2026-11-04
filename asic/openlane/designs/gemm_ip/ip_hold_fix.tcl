# ---------------------------------------------------------------------------
# ip_hold_fix.tcl - hold repair on the post-CTS layout of gemm_ip, before the
# global route of ip-route. Run by ip_resume.tcl (run_openroad_script), which
# restores the views from before this step if OpenROAD fails.
#
# Why: CTS hold repair of the IP ran without the macro libs in the signoff
# picture; with them (Typical, macro libs, placement parasitics, SDC at 20 ns)
# the post-CTS layout of ip_v3 has one endpoint under +0.1 ns:
#   _56750_/Q -> u_axi_shell/i_weight_ready  -0.315 ns  (ip_v2 signoff: -0.091)
# Steps:
#   - Typical library + EXTRA_LIBS (SRAM, rows, AXI macro: one typical lib each);
#   - propagated clock (in the post-CTS SDC), parasitics estimated from placement;
#   - repair_timing -hold -skip_pin_swap, hold margin GEMM_IP_HOLD_MARGIN [0.1 ns],
#     at most GEMM_IP_HOLD_MAX_BUFFER_PERCENT [1] % buffers, setup margin
#     GLB_RESIZER_SETUP_SLACK_MARGIN; only if an endpoint is under the margin;
#   - detailed placement, check_placement;
#   - "gemm_hold_fix: changed N", run time and peak memory at the end of the log.
# ---------------------------------------------------------------------------
set hf_t0 [clock seconds]
source $::env(SCRIPTS_DIR)/openroad/common/io.tcl
read -no_spefs -lib_typical $::env(RSZ_LIB)

proc hf_env {name default} {
    return [expr {[info exists ::env($name)] ? $::env($name) : $default}]
}
set margin  [hf_env GEMM_IP_HOLD_MARGIN 0.1]
set max_buf [hf_env GEMM_IP_HOLD_MAX_BUFFER_PERCENT 1]

set_propagated_clock [all_clocks]
source $::env(SCRIPTS_DIR)/openroad/common/resizer.tcl
set_dont_touch_wrapper
if { [info exists ::env(DONT_USE_CELLS)] } {
    set_dont_use $::env(DONT_USE_CELLS)
}
source $::env(SCRIPTS_DIR)/openroad/common/set_rc.tcl
estimate_parasitics -placement

# endpoints with hold slack under the margin (count, worst in ns)
proc hf_report {tag margin} {
    set n 0
    foreach pe [find_timing_paths -path_delay min -group_count 500000 -endpoint_count 1 -sort_by_slack -slack_max [expr {$margin * 1e-9}]] {
        incr n
        if { $n <= 20 } {
            puts [format "gemm_hold_fix: %s: %8.3f ns  %s -> %s" $tag [expr {[$pe slack] * 1e9}] \
                [get_full_name [get_property $pe startpoint]] [get_full_name [get_property $pe endpoint]]]
        }
    }
    puts "gemm_hold_fix: $tag: $n endpoint(s) under +$margin ns;\
          hold wns [format %.3f [expr {[sta::worst_slack_cmd min] * 1e9}]],\
          setup wns [format %.3f [expr {[sta::worst_slack_cmd max] * 1e9}]] (ns, Typical, macro libs, placement parasitics, period $::env(CLOCK_PERIOD) ns)"
    return $n
}
proc hf_masters {} {
    set m [dict create]
    foreach inst [[ord::get_db_block] getInsts] {
        dict set m [$inst getName] [[$inst getMaster] getName]
    }
    return $m
}

set before [hf_masters]
if { [hf_report "before" $margin] == 0 } {
    puts "gemm_hold_fix: no endpoint under the margin - repair skipped"
} else {
    repair_timing -hold -skip_pin_swap -setup_margin $::env(GLB_RESIZER_SETUP_SLACK_MARGIN) \
        -hold_margin $margin -max_buffer_percent $max_buf
    hf_report "after" $margin
}
set after [hf_masters]
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
puts "gemm_hold_fix: changed [expr {$resized + $added + $removed}] ($resized resized, $added added, $removed removed)"

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
puts "gemm_hold_fix: runtime [expr {[clock seconds] - $hf_t0}] s, peak memory [expr {$hwm eq "?" ? "?" : $hwm / 1024}] MB"
