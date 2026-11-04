# 4a helper: one pin (bbox and layer) of every non-special net with pins but no wire.
source [file join [file dirname [file normalize [info script]]] common.tcl]
read_def $P/in/GEMM_top.round1.def
set fo [open $P/s4a/pins_nowire.tsv w]; set n 0; set nopin 0
foreach net [[ord::get_db_block] getNets] {
  if { [$net isSpecial] || [$net getWire] ne "NULL" } { continue }
  set done 0
  foreach it [$net getITerms] {
    set mp [lindex [[$it getMTerm] getMPins] 0]
    if { $mp eq "" } { continue }
    set g [lindex [$mp getGeometry] 0]
    set b [$it getBBox]
    puts $fo [join [list [$net getName] [[$g getTechLayer] getName] [$b xMin] [$b yMin] [$b xMax] [$b yMax]] \t]
    set done 1; break
  }
  if { !$done } {
    foreach bt [$net getBTerms] {
      foreach bp [$bt getBPins] {
        set bx [lindex [$bp getBoxes] 0]
        puts $fo [join [list [$net getName] [[$bx getTechLayer] getName] [$bx xMin] [$bx yMin] [$bx xMax] [$bx yMax]] \t]
        set done 1; break
      }
      if { $done } { break }
    }
  }
  if { $done } { incr n } else { incr nopin }
}
close $fo
puts "PROBE nets without wire: with a pin $n, without any pin $nopin; [el]"
