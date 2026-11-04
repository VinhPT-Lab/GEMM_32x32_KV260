# ---------------------------------------------------------------------------
# keep_rows_clear.tcl - sourced right before every detailed_placement of
# gemm_core (OpenLane's common/dpl_cell_pad.tcl, hook added by run_flow.sh;
# config.tcl sets DPL_PRE_HOOK). Placement, CTS, post-CTS resizer, diode
# legalisation.
#
# Why: the row macros block met1-met4, so a standard cell that ends up in a
# channel between two rows can only reach anything outside that channel by
# crossing a row vertically - impossible for the router. core_v4/core_v5 had
# ~1300 such cells (tools/core_channels.py): repair_design puts its "wire"
# repeaters on the straight line between a Steiner point and a load, and the
# long nets from the feeder (left, at each lane's height) to row 31's weight
# pins (bottom right) run diagonally across the row stack, so the repeaters
# were legalised into the channels. Result: ~6k gcell edges of vertical
# overflow over the rows and ~9.5k shorts left by the detailed router.
#
# What: every movable standard cell whose centre lies in a channel is moved
# to the nearer free side - west into the FeatureSkew strip or south into the
# OutputDeskew band - at the same y or x; detailed_placement then legalises it
# there. Hold buffers stay (name hold*): the resizer puts them on the
# row-to-row nets (weight / psum chain between neighbouring rows) and those
# belong in the channel (array lesson). The band above row 0 is left alone
# (tie cells of row 0's psum inputs).
# ---------------------------------------------------------------------------
proc gemm_keep_rows_clear {} {
    set block [[[::ord::get_db] getChip] getBlock]
    set dbu [$block getDefUnits]
    set rows {}
    foreach inst [$block getInsts] {
        if { [[$inst getMaster] getName] eq "ProcessingElementRow" } {
            set b [$inst getBBox]
            lappend rows [list [$b xMin] [$b yMin] [$b xMax] [$b yMax]]
        }
    }
    if { [llength $rows] < 2 } {
        puts "\[INFO\]: keep_rows_clear: [llength $rows] row macros found - nothing to do"
        return
    }
    set rows [lsort -integer -index 1 $rows]
    set x0 [lindex $rows 0 0]
    set x1 [lindex $rows 0 2]
    foreach r $rows {
        if { [lindex $r 0] < $x0 } { set x0 [lindex $r 0] }
        if { [lindex $r 2] > $x1 } { set x1 [lindex $r 2] }
    }
    set ybot [lindex $rows 0 1]
    set chans {}
    for { set i 0 } { $i < [llength $rows] - 1 } { incr i } {
        lappend chans [list [lindex $rows $i 3] [lindex $rows [expr {$i + 1}] 1]]
    }
    set lo [lindex $chans 0 0]
    set hi [lindex $chans end 1]
    set gap [expr {int(20 * $dbu)}]
    set west 0
    set south 0
    set kept 0
    foreach inst [$block getInsts] {
        if { [$inst isFixed] || ![$inst isPlaced] } { continue }
        set master [$inst getMaster]
        if { ![string match "sky130_fd_sc*" [$master getName]] } { continue }
        set b [$inst getBBox]
        set cx [expr {([$b xMin] + [$b xMax]) / 2}]
        set cy [expr {([$b yMin] + [$b yMax]) / 2}]
        if { $cx < $x0 || $cx > $x1 || $cy < $lo || $cy > $hi } { continue }
        set inside 0
        foreach c $chans {
            if { $cy >= [lindex $c 0] && $cy <= [lindex $c 1] } { set inside 1; break }
        }
        if { !$inside } { continue }
        if { [string match "*hold*" [$inst getName]] } { incr kept; continue }
        set w [expr {[$b xMax] - [$b xMin]}]
        set h [expr {[$b yMax] - [$b yMin]}]
        if { $cx - $x0 <= $cy - $ybot } {
            $inst setLocation [expr {$x0 - $gap - $w}] [$b yMin]
            incr west
        } else {
            $inst setLocation [$b xMin] [expr {$ybot - $gap - $h}]
            incr south
        }
    }
    puts "\[INFO\]: keep_rows_clear: moved [expr {$west + $south}] cells out of the channels between\
          the row macros ($west west into the FeatureSkew strip, $south south into the OutputDeskew band);\
          $kept hold buffers left in place"
}
gemm_keep_rows_clear
