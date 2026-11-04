# 4a check: every pin of every non-special net: net, pin, its layers, bbox.
source [file join [file dirname [file normalize [info script]]] common.tcl]
read_def [expr {[info exists ::env(DEF)] ? $::env(DEF) : "$P/in/GEMM_top.round1.def"}]
set fo [open [expr {[info exists ::env(OUTF)] ? $::env(OUTF) : "$P/s4a/pins_all.tsv"}] w]; set n 0
array set lay {}
foreach net [[ord::get_db_block] getNets] {
  if { [$net isSpecial] } { continue }
  set nn [$net getName]
  foreach it [$net getITerms] {
    set m [$it getMTerm]
    if { [$m getSigType] eq "POWER" || [$m getSigType] eq "GROUND" } { continue }
    set key [[$m getMaster] getName]/[$m getName]
    if { ![info exists lay($key)] } {
      set ls {}
      foreach mp [$m getMPins] { foreach g [$mp getGeometry] { set l [$g getTechLayer]; if { $l ne "NULL" && [$l getType] eq "ROUTING" } { lappend ls [$l getName] } } }
      set lay($key) [lsort -unique $ls]
    }
    set b [$it getBBox]
    puts $fo [join [list $nn I [[$it getInst] getName]/[$m getName] [join $lay($key) ,] [$b xMin] [$b yMin] [$b xMax] [$b yMax]] \t]
    incr n
  }
  foreach bt [$net getBTerms] {
    foreach bp [$bt getBPins] {
      foreach bx [$bp getBoxes] {
        puts $fo [join [list $nn B [$bt getName] [[$bx getTechLayer] getName] [$bx xMin] [$bx yMin] [$bx xMax] [$bx yMax]] \t]
        incr n
      }
    }
  }
}
close $fo
puts "PROBE pins written: $n; [el]"
