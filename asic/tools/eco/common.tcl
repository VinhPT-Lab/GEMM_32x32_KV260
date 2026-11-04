# Shared setup for the OpenROAD dcf3613 (LibreLane 3.0.16) probe: the PDK and macro
# LEFs of the OpenLane 1.0.2 flow (PDK under $PDK_ROOT, not the image's PDK).
set P $::env(ECO_DIR)
set PDK $::env(PDK_ROOT)/sky130A
set t0 [clock seconds]
proc mem {} { return [expr {[lindex [exec grep VmRSS /proc/[pid]/status] 1]/1024}] }
proc hwm {} { return [expr {[lindex [exec grep VmHWM /proc/[pid]/status] 1]/1024}] }
proc el {} { return "[expr {[clock seconds]-$::t0}] s, RSS [mem] MB, peak [hwm] MB" }
read_lef $PDK/libs.ref/sky130_fd_sc_hd/techlef/sky130_fd_sc_hd__nom.tlef
read_lef $PDK/libs.ref/sky130_fd_sc_hd/lef/sky130_ef_sc_hd.lef
read_lef $PDK/libs.ref/sky130_fd_sc_hd/lef/sky130_fd_sc_hd.lef
read_lef $P/lef/ProcessingElementRow.lef
read_lef $P/lef/sram_antenna.lef
read_lef $P/lef/GemmAxiShell_antenna.lef
set_thread_count 8
# routing setup of ip_v3r (OpenLane 1.0.2 set_routing_layers / set_layer_adjustments)
proc route_setup {} {
  set_routing_layers -signal met1-met5 -clock met3-met5
  set_global_routing_layer_adjustment * 0.3
  foreach l {met1 met2 met3 met4 met5} a {0.99 0.5 0 0 0} { set_global_routing_layer_adjustment $l $a }
  set_macro_extension 0
}
proc ant_count {tag} {
  set rpt $::P/$tag.ant.rpt
  set n [check_antennas -report_file $rpt -verbose]
  puts "PROBE $tag check_antennas: $n nets; [el]"
  return $n
}
