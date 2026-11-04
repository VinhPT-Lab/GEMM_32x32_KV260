# 6b: one STA corner of one layout (OpenROAD of OpenLane 1.0.2, read-only).
#   DES = v3r | eco      ip_v3r round 1 (kept, signoff SPEF)  |  ECO layout after 6a
#   C   = tt | ff | ss   standard-cell lib; macros (SRAM, row, AXI) their only lib (typical)
#   RC  = min | nom | max
# Propagated clock, final SDC of ip_v3r. Every endpoint's worst setup and hold path,
# split by kind: cell->cell, touching a macro (SRAM / row / AXI), I/O (a port at
# either end). Output: sta6b/<DES>_<C>_<RC>.{setup,hold}.tsv and a summary line.
# DRV=1: also max slew / max cap against the LIBERTY limits (SDC set_max_transition /
# set_max_fanout removed), split cell / SRAM dout cap / SRAM addr-wmask slew (waived) /
# other SRAM / row-AXI pins, counted by net.
set P $::env(ECO_DIR)
set DES $::env(DES); set C $::env(C); set RC $::env(RC)
set L $::env(PDK_ROOT)/sky130A/libs.ref
set t0 [clock seconds]
array set LIB {tt tt_025C_1v80 ff ff_n40C_1v95 ss ss_100C_1v60}
read_liberty $L/sky130_fd_sc_hd/lib/sky130_fd_sc_hd__$LIB($C).lib
read_liberty $L/sky130_sram_macros/lib/sky130_sram_2kbyte_1rw1r_32x512_8_TT_1p8V_25C.lib
read_liberty $P/lib/ProcessingElementRow.lib
read_liberty $P/lib/GemmAxiShell.lib
if { $DES eq "v3r" } {
    read_db $::env(V3R_ODB)   ;# ip_v3r: ODB of the kept routing round
    set spef $P/in/GEMM_top.$RC.spef
} else {
    read_db $::env(ECO_ODB)
    set spef $::env(ECO_SPEF_DIR)/process_corner_$RC/GEMM_top.spef
}
file mkdir $P/sta6b
set sdc $P/in/GEMM_top.sdc
if { [info exists ::env(DRV)] && $::env(DRV) } {
    set fi [open $sdc]; set fo [open /tmp/sta6b_lib_$DES$C$RC.sdc w]
    while { [gets $fi line] >= 0 } { if { ![regexp {^set_max_(transition|fanout)} $line] } { puts $fo $line } }
    close $fi; close $fo
    read_sdc /tmp/sta6b_lib_$DES$C$RC.sdc
} else {
    read_sdc $sdc
}
set_propagated_clock [all_clocks]
read_spef $spef

proc kind {pin} {
    set inst [$pin instance]
    if { $inst eq "NULL" || [$inst parent] eq "NULL" } { return io }
    set ref [get_property $inst ref_name]
    if { [string match "sky130_fd_sc*" $ref] || [string match "sky130_ef_sc*" $ref] } { return cell }
    return macro
}
set summary "STA6B $DES $C RC $RC:"
foreach {mode dly} {setup max hold min} {
    set out [open $P/sta6b/${DES}_${C}_$RC.$mode.tsv w]
    array unset n; array unset w
    foreach k {cc cm io} { set n($k) 0; set w($k) 1e9; set tot($k) 0 }
    foreach path [find_timing_paths -path_delay $dly -group_count 3000000 -endpoint_count 1 -unique_paths_to_endpoint] {
        set s [get_property $path slack]
        if { $s eq "" || $s > 1e10 || $s < -1e10 } { continue }
        set ep [get_property $path endpoint]; set sp [get_property $path startpoint]
        set ke [kind $ep]; set ks [kind $sp]
        if { $ke eq "io" || $ks eq "io" } { set k io } elseif { $ke eq "macro" || $ks eq "macro" } { set k cm } else { set k cc }
        incr tot($k)
        if { $s < $w($k) } { set w($k) $s }
        if { $s < 0 } { incr n($k) }
        puts $out [format "%s\t%s\t%.4f\t%s" [get_full_name $ep] [get_full_name $sp] $s $k]
    }
    close $out
    append summary [format " | %s cell->cell worst %.3f (<0: %d/%d), macro worst %.3f (<0: %d/%d), I/O worst %.3f (<0: %d/%d)" \
        $mode $w(cc) $n(cc) $tot(cc) $w(cm) $n(cm) $tot(cm) $w(io) $n(io) $tot(io)]
}
puts $summary

if { [info exists ::env(DRV)] && $::env(DRV) } {
    set rpt $P/sta6b/${DES}_${C}_$RC.drv.rpt
    report_check_types -max_slew -max_capacitance -violators > $rpt
    set block [ord::get_db_block]
    foreach k {cell_slew cell_cap sram_dout_cap sram_addr_slew sram_other macro_other io} { set D($k) [dict create] }
    set sec ""; set fh [open $rpt]
    while { [gets $fh line] >= 0 } {
        if { [regexp {^max (slew|capacitance)} $line -> s] } { set sec $s; continue }
        if { ![regexp {^(\S+)\s+\S+\s+\S+\s+\S+\s+\(VIOLATED\)} $line -> pin] } { continue }
        set p [sta::find_pin $pin]
        if { $p eq "NULL" } { dict set D(io) $pin 1; continue }
        set inst [$p instance]
        if { $inst eq "NULL" || [$inst parent] eq "NULL" } { dict set D(io) $pin 1; continue }
        set ref [get_property $inst ref_name]
        set net [get_full_name [$p net]]
        if { [string match "sky130_sram*" $ref] } {
            if { $sec eq "slew" && [regexp {/(addr|wmask)} $pin] } { set k sram_addr_slew } \
            elseif { $sec eq "capacitance" && [regexp {/dout} $pin] } { set k sram_dout_cap } else { set k sram_other }
        } elseif { [string match "sky130_*" $ref] } {
            set k [expr {$sec eq "slew" ? "cell_slew" : "cell_cap"}]
        } else { set k macro_other }
        dict set D($k) $net 1
    }
    close $fh
    set cell [dict create]
    foreach k {cell_slew cell_cap} { foreach x [dict keys $D($k)] { dict set cell $x 1 } }
    set fo [open $P/sta6b/${DES}_${C}_$RC.drv_cell_nets.txt w]; puts $fo [join [lsort [dict keys $cell]] \n]; close $fo
    puts "STA6B DRV $DES $C RC $RC (lib limits): standard-cell nets [dict size $cell] (slew [dict size $D(cell_slew)], cap [dict size $D(cell_cap)]);\
          SRAM dout cap nets [dict size $D(sram_dout_cap)]; SRAM addr/wmask slew nets [dict size $D(sram_addr_slew)] (waived);\
          SRAM other [dict size $D(sram_other)]; row/AXI pins [dict size $D(macro_other)]; I/O [dict size $D(io)]"
}
# EXTRA=1 (final check): unconstrained endpoints and clock skew, to files
if { [info exists ::env(EXTRA)] && $::env(EXTRA) } {
    sta::redirect_file_begin $P/sta6b/${DES}_${C}_$RC.unconstrained.rpt
    check_setup -verbose -unconstrained_endpoints
    sta::redirect_file_end
    sta::redirect_file_begin $P/sta6b/${DES}_${C}_$RC.skew.rpt
    report_clock_skew -setup
    report_clock_skew -hold
    sta::redirect_file_end
    puts "STA6B EXTRA $DES $C RC $RC: unconstrained report lines [exec wc -l < $P/sta6b/${DES}_${C}_$RC.unconstrained.rpt]"
}
puts "STA6B time [expr {[clock seconds]-$t0}] s, peak [expr {[lindex [exec grep VmHWM /proc/[pid]/status] 1]/1024}] MB"
