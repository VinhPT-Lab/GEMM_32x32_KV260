# 4b: guides built from the round-1 wires (env GUIDE, output dir env OUTD).
# Read DEF + guides, write back, antenna check, then an empty ECO:
# detailed_route with the options of 4c and nothing changed.
source [file join [file dirname [file normalize [info script]]] common.tcl]
set D $P/$::env(OUTD); file mkdir $D
read_def $P/in/GEMM_top.round1.def
route_setup
read_guides $::env(GUIDE)
set empty 0; set n 0
foreach net [[ord::get_db_block] getNets] {
  if { [$net isSpecial] } { continue }
  incr n
  if { [llength [$net getGuides]] == 0 } { incr empty }
}
puts "PROBE read_guides: non-special nets $n, without guides $empty; [el]"
write_def $D/guides_rt.def
puts "PROBE write_def after read_guides: [el]"
ant_count $::env(OUTD)/guides
detailed_route -output_drc $D/empty_eco.drt.drc -droute_end_iter 64 -or_seed 42 -verbose 1
puts "PROBE detailed_route (empty ECO) done: [el]"
write_def $D/empty_eco.def
ant_count $::env(OUTD)/empty_eco
puts "PROBE 4b done: [el]"
