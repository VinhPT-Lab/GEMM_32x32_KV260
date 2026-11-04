# Power of one flat hardened block (PE, row) at TT with its signoff SPEF, from a
# simulation activity file (vcd2act_flat.py), as tools/power/shell_power.tcl does for
# the AXI shell: per-pin activity on the driver pin of every net and on input ports.
# env: FINAL (results/final of the block run), DESIGN, OUT (report prefix), ACT,
#      PERIOD (ns, optional: re-create the clock at this period, e.g. 20 for 50 MHz),
#      SPEF (optional, default FINAL/spef/DESIGN.spef)
set R $::env(FINAL); set D $::env(DESIGN)
set lib $::env(PDK_ROOT)/sky130A/libs.ref
read_liberty $lib/sky130_fd_sc_hd/lib/sky130_fd_sc_hd__tt_025C_1v80.lib
read_verilog $R/verilog/gl/$D.nl.v
link_design $D
read_sdc $R/sdc/$D.sdc
if {[info exists ::env(PERIOD)]} {
    set clk [lindex [all_clocks] 0]
    set src [get_property $clk sources]
    create_clock -name [get_name $clk] -period $::env(PERIOD) $src
    set_propagated_clock [all_clocks]
}
read_spef [expr {[info exists ::env(SPEF)] ? $::env(SPEF) : "$R/spef/$D.spef"}]
set f [open $::env(ACT)]; set ncyc 0; set np 0; set nport 0; set nmiss 0
while {[gets $f line] >= 0} {
    if {[string index $line 0] eq "#"} { set ncyc [lindex $line 2]; continue }
    lassign $line kind name tog duty
    set act [expr {double($tog) / $ncyc}]
    if {$kind eq "pin"} {
        set pin [sta::find_pin $name]
        if {$pin eq "NULL" || $pin eq ""} { incr nmiss; continue }
        if {[sta::is_clock_src $pin]} { continue }
        sta::set_power_pin_activity $pin $act $duty
        incr np
    } elseif {$kind eq "port"} {
        set port [get_ports -quiet $name]
        if {$port eq ""} { incr nmiss; continue }
        if {[sta::is_clock_src [sta::get_port_pin $port]]} { continue }
        set_power_activity -input_ports $port -activity $act -duty $duty
        incr nport
    }
}
close $f
puts "activity from [file tail $::env(ACT)]: $np driver pins, $nport input ports over $ncyc cycles, $nmiss not found"
puts "clock period [get_property [lindex [all_clocks] 0] period] ns"
report_power
report_power -digits 6 > $::env(OUT).design.rpt
