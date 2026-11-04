# per-layer RC from the tech LEF (needed by the resizer: on GRT routes it takes wire R from
# the layer RC; without it r_wire = 0 and repair_design never buffers a long net)
# per-layer RC from the tech LEF (liberty units: kOhm, pF, per um)
set tech [[ord::get_db] getTech]; set dbu [$tech getDbUnitsPerMicron]
foreach l [$tech getLayers] {
  set n [$l getName]
  if { [$l getType] eq "ROUTING" } {
    set w [expr {[$l getWidth] / double($dbu)}]
    set r [expr {[$l getResistance] / $w / 1000.0}]
    set c [expr {[$l getCapacitance] * $w + 2 * [$l getEdgeCapacitance]}]
    set_layer_rc -layer $n -resistance $r -capacitance $c
    puts "PROBE set_layer_rc $n R $r kOhm/um C $c pF/um"
  } elseif { [$l getType] eq "CUT" && [$l getResistance] > 0 } {
    set_layer_rc -via $n -resistance [expr {[$l getResistance] / 1000.0}]
    puts "PROBE set_layer_rc via $n R [expr {[$l getResistance] / 1000.0}] kOhm"
}
}
