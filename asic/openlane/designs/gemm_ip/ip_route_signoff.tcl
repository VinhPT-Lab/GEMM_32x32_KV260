# ---------------------------------------------------------------------------
# ip_route_signoff.tcl - copy of openlane/designs/gemm_core/route_signoff.tcl
# (commit deaecf4) for gemm_ip, sourced by ip_full.tcl and ip_resume.tcl.
# gemm_core keeps its own file unchanged. Differences from the original:
#   - gemm_ip_timing_eco: after every global route of the antenna ECO rounds
#     (its diodes are in by then), ip_timing_eco.tcl repairs setup (no hold) on the
#     global-route parasitics; if it changed cells, global route again
#     without diode repair (gemm_ip_reroute).
#     GEMM_IP_TIMING_ECO 1 turns it on (default 0 = the original flow). Each
#     round starts again from the pre-global-route database (as the diodes of
#     ant_eco.py do), so the repair is redone per round and the kept round has its own.
#   - signoff order: antenna and Magic DRC before LVS, LVS in a catch (a
#     mismatch or a failed netgen is reported, the flow goes on).
#   - detailed routing through ip_droute.tcl (gemm_detailed_routing), which
#     passes -or_k GEMM_DRT_OR_K [0.05] with the seed: with OpenLane's
#     droute.tcl (or_k 0) every seed of GEMM_DRT_SEEDS routed the same.
# ---------------------------------------------------------------------------
# (original header) route_signoff.tcl - routing and every signoff step of gemm_core, after CTS.
# Sourced by resume.tcl (core-route: a new run from the post-CTS views of an
# earlier one) and by core_full.tcl (core: the whole flow), so both get the
# same guards:
#   - detailed routing retried with other router seeds until clean
#     (gemm_drt_seeds), the attempt with the fewest violations kept;
#   - antenna ECO rounds after routing (gemm_ant_eco, ant_eco.py);
#   - no LVS on a layout that still has shorts (netgen would run for hours);
#   - informational steps (IR drop, KLayout, CVC) cannot fail the run.
# Expects OpenLane loaded, a prepared run and CURRENT_* at the post-CTS views.
# ---------------------------------------------------------------------------

# a step whose failure should not throw away the signoff that already ran
proc soft_step {name body} {
    set ::env(EXIT_ON_ERROR) 0
    if { [catch { uplevel 1 $body } e] } {
        puts_warn "gemm: $name failed ($e) - continuing, it is informational for this core"
    }
    set ::env(EXIT_ON_ERROR) 1
}


# violations the detailed router left (reports/routing/drt.drc), -1 = no report
proc gemm_drt_count {} {
    set f $::env(routing_reports)/drt.drc
    if { ![file exists $f] } { return -1 }
    set n 0
    set fh [open $f]
    while { [gets $fh line] >= 0 } { if { [string match "*violation type*" $line] } { incr n } }
    close $fh
    return $n
}

set gemm_ip_dir [file dirname [file normalize [info script]]]

# OpenLane's detailed_routing_tritonroute (scripts/tcl_commands/routing.tcl),
# with ip_droute.tcl in place of droute.tcl (seed + or_k, both in the log)
proc gemm_detailed_routing {} {
    increment_index
    TIMER::timer_start
    set log [index_file $::env(routing_logs)/detailed.log]
    puts_info "Running Detailed Routing, seed $::env(DRT_OR_SEED), or_k\
               [expr {[info exists ::env(GEMM_DRT_OR_K)] ? $::env(GEMM_DRT_OR_K) : 0.05}] (log: [relpath . $log])..."

    set ::env(_tmp_drt_file_prefix) $::env(routing_tmpfiles)/drt
    set ::env(_tmp_drt_rpt_prefix) $::env(routing_reports)/drt
    run_openroad_script $::gemm_ip_dir/ip_droute.tcl\
        -indexed_log $log\
        -save "to=$::env(routing_results),noindex,def,odb,netlist,powered_netlist"

    try_exec python3 $::env(SCRIPTS_DIR)/drc_rosetta.py tr to_klayout \
        -o $::env(routing_reports)/drt.klayout.xml \
        --design-name $::env(DESIGN_NAME) \
        $::env(routing_reports)/drt.drc

    if { $::env(QUIT_ON_TR_DRC) } {
        quit_on_tr_drc
    }

    TIMER::timer_stop
    exec echo "[TIMER::get_runtime]" | python3 $::env(SCRIPTS_DIR)/write_runtime.py "detailed_routing - openroad"
}

# Detailed routing from the current global route. The router is deterministic
# for a given seed, so a run that leaves a violation it cannot clear (core_v6:
# one met5 short after 64 iterations) would leave it again: it is repeated from
# the same global route with the next seed of GEMM_DRT_SEEDS until one comes out
# clean; if none does, the attempt with the fewest violations is kept. A router
# crash under one seed just moves on to the next one. Sets GEMM_DRT_LEFT.
proc gemm_drt_seeds {} {
    set ::env(GEMM_DRT_LEFT) 0
    set ::env(QUIT_ON_TR_DRC) 0     ;# a dirty attempt moves on to the next seed
    if { $::env(RUN_DRT) } {
        if { [info exists ::env(GEMM_DRT_SEEDS)] && [llength $::env(GEMM_DRT_SEEDS)] } {
            set seeds $::env(GEMM_DRT_SEEDS)
        } elseif { [info exists ::env(DRT_OR_SEED)] } {
            set seeds [list $::env(DRT_OR_SEED)]
        } else {
            set seeds [list 42]
        }
        set pre_odb $::env(CURRENT_ODB)
        set pre_def $::env(CURRENT_DEF)
        set keep $::env(routing_tmpfiles)/drt_attempts
        file mkdir $keep
        set tried [list]
        set cur ""      ;# seed whose routed views are the CURRENT_* ones
        foreach seed $seeds {
            set ::env(DRT_OR_SEED) $seed
            set_odb $pre_odb
            set_def $pre_def
            set cur ""
            puts_info "gemm: detailed routing with seed $seed (seeds to try: $seeds)"
            set ::env(EXIT_ON_ERROR) 0
            set crashed [catch { gemm_detailed_routing } e]
            set ::env(EXIT_ON_ERROR) 1
            set log $::env(routing_logs)/$::env(CURRENT_INDEX)-detailed.log
            if { $crashed } {
                puts_warn "gemm: detailed routing with seed $seed failed ($e) - trying the next seed"
                exec echo "seed $seed: router failed" >> $::env(routing_reports)/drt_seeds.txt
                continue
            }
            set n [gemm_drt_count]
            puts_info "gemm: detailed routing with seed $seed left $n violation(s)"
            exec echo "seed $seed (or_k [expr {[info exists ::env(GEMM_DRT_OR_K)] ? $::env(GEMM_DRT_OR_K) : 0.05}]): $n violation(s)" >> $::env(routing_reports)/drt_seeds.txt
            set files [list $::env(CURRENT_ODB) $::env(CURRENT_DEF) $::env(CURRENT_NETLIST) \
                           $::env(CURRENT_POWERED_NETLIST) $::env(routing_reports)/drt.drc $log]
            # a clean attempt ends the loop and stays current: only dirty ones are kept aside
            if { $n != 0 } { foreach f $files { catch { file copy -force $f $keep/seed$seed.[file tail $f] } } }
            lappend tried [list $seed $n $files]
            set cur $seed
            if { $n == 0 } { break }
        }
        if { ![llength $tried] } {
            puts_err "gemm: detailed routing failed with every seed ($seeds)"
            flow_fail
        }
        set best [lindex [lsort -integer -index 1 [lsearch -all -inline -not -regexp $tried {^\S+ -1 }]] 0]
        if { $best eq "" } { set best [lindex $tried end] }
        # put the best attempt back unless its views are the current ones - also
        # after a later attempt crashed, which leaves CURRENT_* at the
        # pre-routing views. The router always writes the same files
        # (results/routing/<design>.*), so the kept copies go back over them;
        # its log gets the newest step index for the final report.
        if { [lindex $best 0] ne $cur } {
            set seed [lindex $best 0]
            set files [lindex $best 2]
            foreach f [lrange $files 0 4] {
                catch { file copy -force $keep/seed$seed.[file tail $f] $f }
            }
            increment_index
            catch { file copy -force $keep/seed$seed.[file tail [lindex $files 5]] \
                        [index_file $::env(routing_logs)/detailed.log] }
            set_odb [lindex $files 0]
            set_def [lindex $files 1]
            set_netlist [lindex $files 2]
            set ::env(CURRENT_POWERED_NETLIST) [lindex $files 3]
            puts_info "gemm: kept the attempt with seed $seed ([lindex $best 1] violation(s))"
        }
        set ::env(GEMM_DRT_LEFT) [lindex $best 1]
    }
}

# ---- antenna ECO -----------------------------------------------------------
# core_v6: 146 antenna violations after routing, every one on a net that had a
# heuristic diode 3-15 um from the pin. 114 were met1 islands with no diode in
# them (the router wired the diode to the net through met2 somewhere else, the
# gate saw up to 1100 um of met1 alone); 25 had the diode but a met3/met4 wire
# too long for one diode. The global-route antenna repair cannot see either.
# So after detailed routing: antenna check -> ant_eco.py puts diodes next to the
# violating gates in the database from before global routing (cumulative over
# the rounds) -> global + detailed routing again -> check. GEMM_ANT_ECO_ITERS
# rounds at most (0 = off), stopping early when clean or when a round does not
# improve; the round with the fewest DRT violations, then antenna violations,
# is kept. GEMM_ANT_ECO_RPT (optional): violator report of an earlier run of
# the same netlist, applied before the first global route (saves a round).

# pin violations listed in an ARC antenna_violators.rpt, -1 if there is none
proc gemm_ant_count {rpt} {
    if { $rpt eq "" || ![file exists $rpt] } { return -1 }
    set n 0
    set fh [open $rpt]
    while { [gets $fh line] >= 0 } { if { [string match "*Partial/Required:*" $line] } { incr n } }
    close $fh
    return $n
}

# diodes for the violations of $rpt into the pre-global-route database $base,
# then legalized; leaves CURRENT_ODB/DEF/NETLIST/POWERED_NETLIST at the result
proc gemm_ant_eco {base rpt tag} {
    increment_index
    set log [index_file $::env(routing_logs)/ant_eco_$tag.log]
    set out [index_file $::env(routing_tmpfiles)/ant_eco_$tag]
    puts_info "gemm: antenna ECO $tag: diodes for the [gemm_ant_count $rpt] violation(s) in [relpath . $rpt] (log: [relpath . $log])"
    manipulate_layout $::env(DESIGN_DIR)/ant_eco.py -indexed_log $log -input $base \
        -output $out.odb -output_def $out.def \
        --violators $rpt --tag $tag --diode-cell $::env(DIODE_CELL) --diode-pin $::env(DIODE_CELL_PIN)
    set_odb $out.odb
    set_def $out.def
    increment_index
    set log [index_file $::env(routing_logs)/ant_eco_${tag}_legalization.log]
    puts_info "gemm: legalizing the ECO diodes (log: [relpath . $log])"
    run_openroad_script $::env(SCRIPTS_DIR)/openroad/dpl.tcl -indexed_log $log \
        -save "to=$::env(routing_tmpfiles),name=[index_file ant_eco_${tag}_legalized],noindex,def,odb,netlist,powered_netlist"
    if { ![catch { exec grep -q -i "fail" $log }] } {
        error "legalizing the ECO diodes failed (see [relpath . $log])"
    }
}

proc gemm_views {} {
    return [list $::env(CURRENT_ODB) $::env(CURRENT_DEF) $::env(CURRENT_NETLIST) $::env(CURRENT_POWERED_NETLIST)]
}

proc gemm_set_views {v} {
    set_odb [lindex $v 0]
    set_def [lindex $v 1]
    set_netlist [lindex $v 2]
    set ::env(CURRENT_POWERED_NETLIST) [lindex $v 3]
}

# copy the routed views + their DRT/antenna reports to $dir/$name.*; returns the copies
proc gemm_keep_round {dir name rpt} {
    set out [list]
    foreach f [gemm_views] {
        set c $dir/$name.[file tail $f]
        file copy -force $f $c
        lappend out $c
    }
    set drc $::env(routing_reports)/drt.drc
    lappend out [expr {[file exists $drc] ? [file copy -force $drc $dir/$name.drt.drc] : ""}]
    set logs [lsort -dictionary [glob -nocomplain $::env(routing_logs)/*-detailed.log]]
    set dlog [expr {[llength $logs] ? [lindex $logs end] : ""}]
    if { $dlog ne "" } { file copy -force $dlog $dir/$name.detailed.log }
    lappend out [expr {$dlog ne "" ? "$dir/$name.detailed.log" : ""}]
    if { $rpt ne "" && [file exists $rpt] } { file copy -force $rpt $dir/$name.antenna_violators.rpt }
    lappend out [expr {$rpt ne "" && [file exists $rpt] ? "$dir/$name.antenna_violators.rpt" : ""}]
    return $out
}

# OpenLane 1.0.2 run_routing (tcl_commands/routing.tcl), step for step, plus the
# seed loop (gemm_drt_seeds) and the antenna ECO rounds above.
# Global route that leaves a net THROUGH a macro (core_v7r: net3191 on met2
# straight across an SRAM - met1-met4 blocked by the SRAM, met5 by GRT_OBS) is
# a short with every detailed-router seed. macro_cross.py reads the guide and
# stops the run here, before hours of DRT, unless GEMM_MACRO_CROSS_STOP is 0.
# GEMM_MACRO_CROSS_DEPTH: how deep (um) a guide may go before it counts.
proc gemm_macro_cross {round} {
    set rpt $::env(routing_reports)/macro_cross_round$round.rpt
    set cmd [list python3 $::env(DESIGN_DIR)/macro_cross.py \
        --guide $::env(CURRENT_GUIDE) --def $::env(CURRENT_DEF) --lef $::env(MERGED_LEF) \
        --grt-obs [expr {[info exists ::env(GRT_OBS)] ? $::env(GRT_OBS) : ""}] \
        --stop-depth [expr {[info exists ::env(GEMM_MACRO_CROSS_DEPTH)] ? $::env(GEMM_MACRO_CROSS_DEPTH) : 50}] \
        --report $rpt]
    set rc 0
    if { [catch { exec {*}$cmd } out opts] } {
        set code [lindex [dict get $opts -errorcode] 0]
        if { $code eq "CHILDSTATUS" } {
            set rc [lindex [dict get $opts -errorcode] 2]
        } else {
            puts_warn "gemm: macro_cross.py did not run ($out) - no macro-crossing check"
            return
        }
    }
    catch { file copy -force $rpt $::env(routing_reports)/macro_cross.rpt }
    # the summary lines, and every net that goes through a macro
    set deep 0
    foreach line [split $out "\n"] {
        if { [string match "  nets THROUGH*" $line] } { set deep 1; puts_info "macro_cross: [string trim $line]"; continue }
        if { [string match "  nets with a guide*" $line] } { set deep 0; puts_info "macro_cross: [string trim $line]"; continue }
        if { [string match "RESULT:*" $line] } { puts_info "macro_cross: $line"; continue }
        if { $deep && [regexp {^    (\S+) +(\S+) +\d+ guide rect\(s\), up to ([\d.]+) um deep in (\S+)} $line -> n l d m] } {
            puts_err "gemm: global route left $n on $l through $m ($d um deep)"
        }
    }
    if { $rc == 3 } {
        set stop [expr {[info exists ::env(GEMM_MACRO_CROSS_STOP)] ? $::env(GEMM_MACRO_CROSS_STOP) : 1}]
        if { $stop } {
            error "global route left net(s) through a macro (see [relpath . $rpt]) - stopping before detailed routing;\
                   GEMM_MACRO_CROSS_STOP=0 routes on anyway"
        }
        puts_warn "gemm: GEMM_MACRO_CROSS_STOP=0 - detailed routing anyway"
    } elseif { $rc != 0 } {
        puts_warn "gemm: macro_cross.py exit $rc - no macro-crossing check (see [relpath . $rpt])"
    }
}

# setup repair on the global route just made, diodes included (see
# ip_timing_eco.tcl); returns 1 if cells changed (the guides are then stale).
# Like soft_step: if OpenROAD fails or crashes (the in-memory re-route of the
# repaired nets died with SIGSEGV in core layout v3, see gemm_core/config.tcl),
# the views go back to the ones from before this step, a warning is printed and
# the flow goes on.
# global route again after a timing ECO that changed cells: every net gets a
# fresh route before DRT. The diodes of the first global route of the round are
# in the database already, so no repair_antennas this time (it names its diodes
# ANTENNA_1.. again: ip_v3 stopped on ODB-0385, duplicate ANTENNA_1); the nets
# the ECO buffered are left to DRT's antenna repair and the antenna ECO rounds.
# If it fails, the views and guides of the round's first global route (before
# the ECO) come back and the flow goes on; returns 1 on success.
proc gemm_ip_reroute {round pass pre_eco} {
    set grt_ant $::env(GRT_REPAIR_ANTENNAS)
    set ::env(GRT_REPAIR_ANTENNAS) 0
    set ::env(EXIT_ON_ERROR) 0
    set t0 [clock seconds]
    set failed [catch { global_routing } e]
    set ::env(EXIT_ON_ERROR) 1
    set ::env(GRT_REPAIR_ANTENNAS) $grt_ant
    set secs [expr {[clock seconds] - $t0}]
    if { $failed } {
        gemm_set_views [lindex $pre_eco 0]
        set_guide [lindex $pre_eco 1]
        puts_warn "gemm: global route after timing ECO round $round pass $pass failed after $secs s ($e) - views from before the ECO kept, continuing"
        exec echo "round $round pass $pass: global route after timing eco FAILED after $secs s, views from before the eco restored" >> $::env(routing_reports)/ant_eco_rounds.txt
        return 0
    }
    exec echo "round $round pass $pass: global route after timing eco (no diode repair), $secs s" >> $::env(routing_reports)/ant_eco_rounds.txt
    return 1
}

proc gemm_ip_timing_eco {round pass} {
    if { ![info exists ::env(GEMM_IP_TIMING_ECO)] || !$::env(GEMM_IP_TIMING_ECO) } { return 0 }
    set before [gemm_views]
    increment_index
    set t0 [clock seconds]
    set log [index_file $::env(routing_logs)/timing_eco_${round}_$pass.log]
    puts_info "gemm: timing ECO round $round pass $pass: repair_timing on the global route, diodes included (log: [relpath . $log])"
    set ::env(GRT_CONGESTION_REPORT_FILE) $::env(routing_tmpfiles)/timing_eco_${round}_$pass-congestion.rpt
    set ::env(EXIT_ON_ERROR) 0
    set failed [catch {
        run_openroad_script $::env(DESIGN_DIR)/ip_timing_eco.tcl -indexed_log $log \
            -save "to=$::env(routing_tmpfiles),name=[index_file timing_eco_${round}_$pass],noindex,def,odb,netlist,powered_netlist"
    } e]
    set ::env(EXIT_ON_ERROR) 1
    set secs [expr {[clock seconds] - $t0}]
    set n 0
    if { !$failed && [catch { regexp {gemm_timing_eco: changed (\d+)} [exec grep "gemm_timing_eco: changed" $log] -> n }] } {
        set failed 1
        set e "no 'changed' line in the log"
    }
    if { $failed } {
        gemm_set_views $before
        puts_warn "gemm: timing ECO round $round pass $pass failed after $secs s ($e) - views from before it kept, continuing"
        exec echo "round $round pass $pass: timing eco FAILED after $secs s, views restored" >> $::env(routing_reports)/ant_eco_rounds.txt
        return 0
    }
    catch { foreach line [split [exec grep "^gemm_timing_eco:" $log] "\n"] { puts_info "gemm: $line" } }
    set mem "?"
    catch { regexp {peak memory (\S+) MB} [exec grep "gemm_timing_eco: runtime" $log] -> mem }
    exec echo "round $round pass $pass: timing eco changed $n, $secs s, peak $mem MB" >> $::env(routing_reports)/ant_eco_rounds.txt
    if { $n == 0 } {
        # nothing changed, but its detailed placement (keep_rows_clear) may have
        # moved cells: keep the views the guides were made for (ip_v3r stopped on
        # DRT-0218, guide not connected, after a 0-change ECO moved 23 cells)
        gemm_set_views $before
    }
    return [expr {$n > 0}]
}

proc gemm_routing {} {
    run_resizer_design_routing
    run_resizer_timing_routing
    if { [info exists ::env(DIODE_CELL)] && ($::env(DIODE_CELL) ne "") } {
        if { $::env(DIODE_ON_PORTS) ne "none" } { io_diode_insertion }
        if { $::env(RUN_HEURISTIC_DIODE_INSERTION) } { heuristic_diode_insertion }
    }
    add_route_obs

    set rounds [expr {[info exists ::env(GEMM_ANT_ECO_ITERS)] ? $::env(GEMM_ANT_ECO_ITERS) : 0}]
    set can_eco [expr {$::env(RUN_DRT) && [info exists ::env(DIODE_CELL)] && $::env(DIODE_CELL) ne ""
                       && $::env(USE_ARC_ANTENNA_CHECK) == 1}]
    if { !$can_eco } { set rounds 0 }
    set keep $::env(routing_tmpfiles)/ant_eco_rounds
    file mkdir $keep
    # the pre-global-route database each round starts from (gets the ECO diodes)
    set base $keep/base0.odb
    file copy -force $::env(CURRENT_ODB) $base
    set base_views [gemm_views]
    set seed_rpt [expr {[info exists ::env(GEMM_ANT_ECO_RPT)] ? $::env(GEMM_ANT_ECO_RPT) : ""}]
    set tried [list]
    set best ""
    set cur -1          ;# round whose routed views are the CURRENT_* ones (-1: none)
    for { set round 0 } { 1 } { incr round } {
        # diodes first: in round 0 from an earlier run's report (if given), later
        # from the best round's own antenna check
        set rpt_in ""
        if { $round > 0 } {
            set rpt_in [lindex $best 3 6]
        } elseif { $rounds > 0 && [gemm_ant_count $seed_rpt] > 0 } {
            set rpt_in $seed_rpt
        }
        if { $rpt_in ne "" } {
            set ::env(EXIT_ON_ERROR) 0
            set failed [catch {
                gemm_ant_eco $base $rpt_in $round
                set base $keep/base[expr {$round + 1}].odb
                file copy -force $::env(CURRENT_ODB) $base
                set base_views [gemm_views]
            } e]
            set ::env(EXIT_ON_ERROR) 1
            if { $failed } {
                puts_warn "gemm: antenna ECO $round failed ($e)"
                if { $best ne "" } { break }
                gemm_set_views $base_views     ;# round 0: route without the ECO diodes
            }
        }
        global_routing
        # timing ECO, then a fresh global route if it changed cells, up to
        # GEMM_IP_TIMING_ECO_PASSES times (see gemm_ip_reroute)
        set passes [expr {[info exists ::env(GEMM_IP_TIMING_ECO_PASSES)] ? $::env(GEMM_IP_TIMING_ECO_PASSES) : 1}]
        set pre_eco [list [gemm_views] $::env(CURRENT_GUIDE)]
        for { set pass 1 } { $pass <= $passes && [gemm_ip_timing_eco $round $pass] } { incr pass } {
            if { ![gemm_ip_reroute $round $pass $pre_eco] } { break }
        }
        gemm_macro_cross $round
        if { $::env(RUN_FILL_INSERTION) } { ins_fill_cells }
        gemm_drt_seeds
        set drt $::env(GEMM_DRT_LEFT)
        set ant -1
        set rpt ""
        if { $rounds > 0 } {
            set ::env(EXIT_ON_ERROR) 0
            if { [catch { run_antenna_check } e] } {
                puts_warn "gemm: antenna check of routing round $round failed ($e)"
            } elseif { [info exists ::env(ANTENNA_VIOLATOR_LIST)] } {
                set rpt $::env(ANTENNA_VIOLATOR_LIST)
                set ant [gemm_ant_count $rpt]
            }
            set ::env(EXIT_ON_ERROR) 1
            puts_info "gemm: routing round $round: $drt DRT violation(s), $ant antenna violation(s)"
            exec echo "round $round: drt $drt antenna $ant" >> $::env(routing_reports)/ant_eco_rounds.txt
        }
        set this [list $round $drt $ant [gemm_keep_round $keep round$round $rpt]]
        set cur $round
        lappend tried $this
        set better [expr {$best eq ""}]
        if { !$better } {
            set bd [lindex $best 1]
            set ba [lindex $best 2]
            if { ($drt == 0) != ($bd == 0) } {
                set better [expr {$drt == 0}]
            } elseif { $drt != $bd } {
                set better [expr {$drt < $bd}]
            } else {
                set better [expr {$ant >= 0 && ($ba < 0 || $ant < $ba)}]
            }
        }
        if { $better } { set best $this }
        if { $rounds == 0 || $ant <= 0 || $round >= $rounds || !$better || $drt != 0 || $rpt eq "" } {
            break
        }
        set cur -1      ;# the next ECO replaces the CURRENT_* views
    }
    if { [lindex $best 0] != $cur } {
        set files [lindex $best 3]
        gemm_set_views [lrange $files 0 3]
        if { [lindex $files 4] ne "" } { file copy -force [lindex $files 4] $::env(routing_reports)/drt.drc }
        if { [lindex $files 5] ne "" } {
            increment_index
            file copy -force [lindex $files 5] [index_file $::env(routing_logs)/detailed.log]
        }
        set ::env(GEMM_DRT_LEFT) [lindex $best 1]
        puts_info "gemm: kept routing round [lindex $best 0] ([lindex $best 1] DRT, [lindex $best 2] antenna violation(s))"
    }
    check_wire_lengths
    set ::env(timer_routed) [clock seconds]
}

# Magic DRC with the full layout of the standard cells.
# OpenLane 1.0.2 (run_magic_drc) always sets MAGTYPE maglef. With
# MAGIC_DRC_USE_GDS 0, which this core needs (see config.tcl), Magic then reads
# the standard cells as abstracts: the nwell of their VPB pin is there, the N+
# tap of the tap cells is not, so every nwell of the core is reported as
# nwell.4 (core_v6r: 25538 of 25595 boxes, all in standard-cell rows, tap cells
# present in every one). Same step as run_magic_drc, only with MAGTYPE mag:
# standard cells full (as in the GDS stream-out), macros still the abstracts
# from EXTRA_LEFS (each was DRC-checked in its own run).
proc gemm_magic_drc {} {
    increment_index
    TIMER::timer_start
    set log [index_file $::env(signoff_logs)/drc.log]
    puts_info "Running Magic DRC, full standard-cell views (log: [relpath . $log])..."
    set ::env(drc_prefix) $::env(signoff_reports)/drc
    set ::env(MAGTYPE) mag
    run_magic_script $::env(SCRIPTS_DIR)/magic/drc.tcl -indexed_log $log
    puts_info "Converting Magic DRC database to various tool-readable formats..."
    try_exec python3 $::env(SCRIPTS_DIR)/drc_rosetta.py magic to_tcl \
        -o $::env(drc_prefix).tcl $::env(drc_prefix).rpt
    try_exec python3 $::env(SCRIPTS_DIR)/drc_rosetta.py magic to_tr \
        -o $::env(drc_prefix).tr $::env(drc_prefix).rpt
    try_exec python3 $::env(SCRIPTS_DIR)/drc_rosetta.py tr to_klayout \
        -o $::env(drc_prefix).klayout.xml --design-name $::env(DESIGN_NAME) $::env(drc_prefix).tr
    try_exec python3 $::env(SCRIPTS_DIR)/drc_rosetta.py magic to_rdb \
        -o $::env(drc_prefix).rdb $::env(drc_prefix).rpt
    file copy -force $::env(MAGIC_MAGICRC) $::env(signoff_results)/.magicrc
    TIMER::timer_stop
    exec echo "[TIMER::get_runtime]" | python3 $::env(SCRIPTS_DIR)/write_runtime.py "drc - magic"
    if { [info exists ::env(QUIT_ON_MAGIC_DRC)] && $::env(QUIT_ON_MAGIC_DRC) } {
        quit_on_magic_drc -log $::env(drc_prefix).tr
    }
}

if { [catch {
    gemm_routing
    if { $::env(RUN_SPEF_EXTRACTION) } { run_parasitics_sta }
    if { $::env(RUN_IRDROP_REPORT) } { soft_step "IR drop report" { run_irdrop_report } }
    if { $::env(RUN_MAGIC) } { run_magic }
    if { $::env(RUN_KLAYOUT) } { soft_step "KLayout GDS" { run_klayout } }
    if { $::env(RUN_KLAYOUT_XOR) } { soft_step "KLayout XOR" { run_klayout_gds_xor } }
    # antenna before Magic DRC, the longest and largest step here (core_v6r:
    # 43 min with abstract cells, about 13 GB): if Magic dies, the rest of the
    # signoff is already there and Magic_violations stays -1, which
    # check_openlane_run.py reports as MISSING (FAIL), never as a pass
    run_antenna_check
    if { $::env(RUN_MAGIC_DRC) } {
        set ::env(EXIT_ON_ERROR) 0
        if { [catch { gemm_magic_drc } e] } {
            puts_err "gemm: Magic DRC did not finish ($e) - signoff incomplete"
        }
        set ::env(EXIT_ON_ERROR) 1
    }
    # gemm_ip: LVS last, after antenna and Magic DRC. ip_v2's layout did not
    # match (floating wells west of the AXI macro) and netgen was still at it
    # after 3.4 h; with LVS last, one run has every other number even then.
    # A mismatch (QUIT_ON_LVS_ERROR 0) or a failed / stopped netgen is reported
    # (lvs_total_errors, FAIL in check_openlane_run.py), the flow goes on.
    # A layout with shorts never matches, and on a design this size netgen then
    # spends many hours listing every cell as unmatched (core_v6: 7 h, 152 MB of
    # log, killed). The verdict is FAIL either way, so LVS waits for a clean route.
    if { $::env(RUN_LVS) && $::env(GEMM_DRT_LEFT) != 0 } {
        puts_warn "gemm: skipping LVS - detailed routing left $::env(GEMM_DRT_LEFT) violation(s)"
    } elseif { $::env(RUN_LVS) } {
        set ::env(EXIT_ON_ERROR) 0
        if { [catch { run_magic_spice_export; run_lvs } e] } {
            puts_err "gemm: LVS FAIL or did not finish ($e) - continuing"
        }
        set ::env(EXIT_ON_ERROR) 1
    }
    if { $::env(RUN_KLAYOUT_DRC) } { soft_step "KLayout DRC" { run_klayout_drc } }
    if { $::env(RUN_CVC) } { soft_step "CVC" { run_erc } }
} err] } {
    puts_err "gemm: $err"
    flow_fail
}
save_final_views
calc_total_runtime
save_state
generate_final_summary_report
if { [catch {
    check_timing_violations \
        -quit_on_hold_vios [expr $::env(QUIT_ON_TIMING_VIOLATIONS) && $::env(QUIT_ON_HOLD_VIOLATIONS)] \
        -quit_on_setup_vios [expr $::env(QUIT_ON_TIMING_VIOLATIONS) && $::env(QUIT_ON_SETUP_VIOLATIONS)]
}] } {
    flow_fail
}
puts_success "Flow complete."
