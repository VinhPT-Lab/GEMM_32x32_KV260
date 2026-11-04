# ---------------------------------------------------------------------------
# resume.tcl - continue gemm_core from the end of CTS of an earlier run, in a
# NEW run directory, without redoing synthesis/floorplan/placement/CTS (~2.5 h).
# Started by run_flow.sh (core-route / core-probe) through OpenLane's
# interactive mode:
#   make -C $OL quick_run QUICK_RUN_DESIGN="gemm_core -it -file designs/gemm_core/resume.tcl"
# Parameters come from resume_params.tcl next to this file (written by
# run_flow.sh):
#   GEMM_FROM_TAG   run whose post-CTS views are reused        (core_v1)
#   GEMM_NEW_TAG    run directory to create                     (core_v1r)
#   GEMM_MODE       route : routing + all signoff steps, like the normal flow
#                   probe : global route only (grt_probe.tcl) to see congestion
#                   check : antenna check on the source run's routed layout as
#                           it is (no routing) - an early look at a later step
#   GEMM_PROBE_ITERS congestion iterations for the probe (0 = first routing only)
#
# How it works: OpenLane v1 keeps the whole flow state in ::env and writes it to
# <run>/config.tcl when a run stops. prep builds a fresh run (same config.tcl,
# fresh merged LEF/LIB), then this script takes from the old state
#   - CURRENT_ODB/DEF/NETLIST/POWERED_NETLIST/SDC (the post-CTS views; copied
#     into the new run in route mode so the old run can be deleted later)
#   - every variable the floorplan..CTS steps created (VDD_PIN, CORE_AREA,
#     CLOCK_NET, ...) that prep does not set itself.
# ---------------------------------------------------------------------------
package require openlane

set here [file dirname [file normalize [info script]]]
source $here/resume_params.tcl
foreach v {GEMM_FROM_TAG GEMM_NEW_TAG GEMM_MODE} {
    if { ![info exists $v] } { puts stderr "\[ERROR\]: resume_params.tcl does not set $v"; exit 1 }
}
if { ![info exists GEMM_PROBE_ITERS] } { set GEMM_PROBE_ITERS 0 }
if { $GEMM_FROM_TAG eq $GEMM_NEW_TAG } {
    puts stderr "\[ERROR\]: GEMM_NEW_TAG must differ from GEMM_FROM_TAG (prep -overwrite would delete the source)"
    exit 1
}

# ---- 1. the saved state of the source run, read in a safe interpreter
set from_dir $here/runs/$GEMM_FROM_TAG
set from_cfg $from_dir/config.tcl
if { ![file exists $from_cfg] } {
    puts stderr "\[ERROR\]: $from_cfg not found - nothing to resume from"
    exit 1
}
set fh [open $from_cfg]; set state_txt [read $fh]; close $fh
set si [interp create -safe]
if { [catch { $si eval $state_txt } e] } {
    puts stderr "\[ERROR\]: cannot read the saved state $from_cfg: $e"
    exit 1
}
array set OLD [$si eval { array get ::env }]
interp delete $si

foreach k {CURRENT_ODB RUN_DIR} {
    if { ![info exists OLD($k)] || $OLD($k) eq "0" } {
        puts stderr "\[ERROR\]: $from_cfg has no $k - the source run did not get through CTS"
        exit 1
    }
}
if { $GEMM_MODE eq "check" } {
    if { ![file exists $OLD(CURRENT_ODB)] } {
        puts stderr "\[ERROR\]: the layout of $GEMM_FROM_TAG is missing on disk: $OLD(CURRENT_ODB)"
        exit 1
    }
} else {
    # A run that went further than CTS (finished, or died in signoff) saved its
    # final views as CURRENT_*. Route it again from the post-CTS views it left in
    # tmp/cts: the newest <idx>-<design>.resized.odb, with all other views taken
    # from next to it (below), not from the saved state.
    if { ![string match */cts/* $OLD(CURRENT_ODB)] } {
        set best ""
        set best_idx -1
        foreach f [glob -nocomplain $from_dir/tmp/cts/*.resized.odb] {
            if { [regexp {/(\d+)-[^/]*$} $f -> i] && $i > $best_idx } { set best $f; set best_idx $i }
        }
        if { $best ne "" } {
            puts "\[INFO\]: resume: $GEMM_FROM_TAG went past CTS (state: [file tail $OLD(CURRENT_ODB)]);\
                  using its post-CTS views [file tail $best]"
            set OLD(CURRENT_ODB) $best
            foreach k {CURRENT_DEF CURRENT_NETLIST CURRENT_POWERED_NETLIST CURRENT_SDC} { set OLD($k) 0 }
            catch { unset OLD(CURRENT_INDEX) }
        }
    }
    # A run that was killed (Ctrl-C) never wrote its full state: config.tcl then
    # only has the CURRENT_* lines OpenLane edits in place (ODB, DEF, NETLIST).
    # The post-CTS resizer writes all views side by side, so take the rest from
    # next to the ODB: <idx>-<design>.resized.{odb,def,nl.v,pnl.v,sdc}.
    set stem [file rootname $OLD(CURRENT_ODB)]
    foreach {k ext} {CURRENT_DEF .def CURRENT_NETLIST .nl.v CURRENT_POWERED_NETLIST .pnl.v CURRENT_SDC .sdc} {
        if { ![info exists OLD($k)] || $OLD($k) eq "0" || ![file exists $OLD($k)] } {
            if { [file exists $stem$ext] } {
                puts "\[INFO\]: resume: $k not in the saved state, using [file tail $stem$ext]"
                set OLD($k) $stem$ext
            } else {
                puts stderr "\[ERROR\]: $from_cfg has no usable $k and $stem$ext does not exist"
                exit 1
            }
        }
    }
    # the views must be the post-CTS ones (results/cts or tmp/cts)
    if { ![string match */cts/* $OLD(CURRENT_ODB)] } {
        puts stderr "\[ERROR\]: $GEMM_FROM_TAG stopped at '$OLD(CURRENT_ODB)', not after CTS."
        puts stderr "         resume.tcl only continues runs that died in routing or later."
        exit 1
    }
    foreach k {CURRENT_ODB CURRENT_DEF CURRENT_NETLIST CURRENT_POWERED_NETLIST CURRENT_SDC} {
        if { ![file exists $OLD($k)] } {
            puts stderr "\[ERROR\]: $k of $GEMM_FROM_TAG is missing on disk: $OLD($k)"
            exit 1
        }
    }
}

# ---- 2. fresh run directory, same design config (+ overrides.tcl if present)
prep -design gemm_core -tag $GEMM_NEW_TAG -overwrite
puts_info "resume: $GEMM_FROM_TAG -> $GEMM_NEW_TAG (mode $GEMM_MODE)"

# ---- 3. variables created by floorplan..CTS
set old_run $OLD(RUN_DIR)
set skip {^(RUN_|RESULTS_DIR$|TMP_DIR$|LOGS_DIR$|REPORTS_DIR$|GLB_CFG_FILE$|START_TIME$|timer_|FLOW_FAILED$|CURRENT_|SAVE_|PWD$|OLDPWD$|TERMINAL_OUTPUT$|LAST_TIMING_REPORT_TAG$|GRT_CONGESTION_REPORT_FILE$|[A-Z_]+_CURRENT_DEF$)}
set restored [list]
foreach k [lsort [array names OLD]] {
    if { [info exists ::env($k)] } { continue }
    if { [regexp $skip $k] } { continue }
    if { [string first $old_run $OLD($k)] >= 0 } { continue }
    set ::env($k) $OLD($k)
    lappend restored $k
}
puts_info "resume: restored [llength $restored] state variables: $restored"
# Power nets exactly as the floorplan step sets them (run_power_grid_generation
# + gen_pdn). VDD_NET matters after CTS: OpenLane's `write` connects the power
# pins of every cell the resizer / antenna repair adds only if VDD_NET exists,
# and a killed run never saved it.
if { [info exists ::env(VDD_NETS)] && [info exists ::env(GND_NETS)] } {
    set ::env(VDD_PIN) [lindex $::env(VDD_NETS) 0]
    set ::env(GND_PIN) [lindex $::env(GND_NETS) 0]
}
foreach {net pin} {VDD_NET VDD_PIN GND_NET GND_PIN} {
    if { ![info exists ::env($net)] && [info exists ::env($pin)] } { set ::env($net) $::env($pin) }
}
foreach k {VDD_PIN GND_PIN VDD_NET GND_NET VDD_NETS GND_NETS} {
    if { ![info exists ::env($k)] } {
        puts_err "resume: $k is not set - cells added after CTS would get no power connection"
        exit 1
    }
}
puts_info "resume: power nets $::env(VDD_NET)/$::env(GND_NET)"

# ---- 4. the post-CTS views
set cts_idx 0
if { [info exists OLD(CURRENT_INDEX)] && [string is integer -strict $OLD(CURRENT_INDEX)] && $OLD(CURRENT_INDEX) > 0 } {
    set cts_idx [expr {$OLD(CURRENT_INDEX) - 1}]
}
regexp {/(\d+)-[^/]*$} $OLD(CURRENT_ODB) -> cts_idx
set ::env(CURRENT_INDEX) $cts_idx
if { $GEMM_MODE eq "route" } {
    # keep the new run self-contained: copy the views and the earlier logs/reports
    foreach k {CURRENT_ODB CURRENT_DEF CURRENT_NETLIST CURRENT_POWERED_NETLIST CURRENT_SDC} {
        set dst $::env(cts_results)/[file tail $OLD($k)]
        file copy -force $OLD($k) $dst
        set NEW($k) $dst
    }
    foreach sub {synthesis floorplan placement cts} {
        foreach kind {logs reports} {
            foreach f [glob -nocomplain $old_run/$kind/$sub/*] {
                catch { file copy -force $f $::env(RUN_DIR)/$kind/$sub/ }
            }
        }
    }
} else {
    foreach k {CURRENT_ODB CURRENT_DEF CURRENT_NETLIST CURRENT_POWERED_NETLIST CURRENT_SDC} {
        set NEW($k) [expr {[info exists OLD($k)] ? $OLD($k) : 0}]
    }
}
set_odb $NEW(CURRENT_ODB)
if { $GEMM_MODE ne "check" } {
    set_def $NEW(CURRENT_DEF)
    set_netlist $NEW(CURRENT_NETLIST)
    set_sdc $NEW(CURRENT_SDC)
    set ::env(CURRENT_POWERED_NETLIST) $NEW(CURRENT_POWERED_NETLIST)
}
save_state "Resumed from $GEMM_FROM_TAG after CTS"
puts_info "resume: ODB [relpath . $::env(CURRENT_ODB)], step index $::env(CURRENT_INDEX)"

# ---- 5a'. check: the antenna check on the routed layout as it is
if { $GEMM_MODE eq "check" } {
    puts_info "resume: antenna check of the routed layout of $GEMM_FROM_TAG"
    run_antenna_check
    puts_info "GEMM_CHECK_DONE"
    exit 0
}

# ---- 5a. probe: global route only
if { $GEMM_MODE eq "probe" } {
    increment_index
    set log [index_file $::env(routing_logs)/grt_probe.log]
    set ::env(GEMM_PROBE_ITERS) $GEMM_PROBE_ITERS
    set ::env(GEMM_PROBE_RPT) $::env(routing_reports)/grt_probe_congestion.rpt
    set ::env(GEMM_PROBE_ODB) $::env(routing_tmpfiles)/grt_probe.odb
    set ::env(GEMM_PROBE_GUIDE) $::env(routing_tmpfiles)/grt_probe.guide
    puts_info "resume: global route probe, $GEMM_PROBE_ITERS congestion iterations (log: [relpath . $log])"
    run_openroad_script $here/grt_probe.tcl -indexed_log $log
    puts_info "GEMM_PROBE_DONE"
    exit 0
}

# ---- 5b. route: routing + signoff, shared with core_full.tcl
source $here/route_signoff.tcl
