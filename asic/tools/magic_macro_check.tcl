# Magic script of tools/magic_macro_check.sh: full DRC (drc(full)) of every
# clip window of clips.gds, every error box printed as
#   GEMM_ERR <window> {<rule>} x0 y0 x1 y1      (um, design coordinates)
# and GEMM_DONE <window> once a window is through.
# env: GEMM_WORK
source $::env(GEMM_WORK)/windows.tcl
gds readonly true
gds read $::env(GEMM_WORK)/clips.gds
set osc [cif scale out]
foreach {n box} $gemm_windows {
    load gemm_clip_$n
    select top cell
    drc euclidean on
    drc style drc(full)
    drc check
    foreach {why boxes} [drc listall why] {
        foreach b $boxes {
            puts [format "GEMM_ERR %d {%s} %.3f %.3f %.3f %.3f" $n $why \
                [expr {$osc * [lindex $b 0]}] [expr {$osc * [lindex $b 1]}] \
                [expr {$osc * [lindex $b 2]}] [expr {$osc * [lindex $b 3]}]]
        }
    }
    puts "GEMM_DONE $n"
}
quit -noprompt
