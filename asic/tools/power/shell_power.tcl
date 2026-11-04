# Power of the AXI shell measurement run (GemmAxiShell) at the typical corner.
# Without ACT: OpenSTA default activity - the same method as the core's
# vectorless number (tools/power.sh without --vcd).
# With ACT (activity file from vcd2act_flat.py): per-pin activity from a
# simulation, set on the driver pin of every net (as power.tcl does for the
# core) and on the input ports too (the shell is mostly port-facing logic;
# measured 2026-10-10, this changed the totals by less than 0.1 %).
#
# Known limit (2026-10-10, OpenSTA of the OpenLane image): in a window where
# a clock gate stays closed the whole time (GCLK 0 toggles), the flops behind
# it and the GCLK net are still charged at the full clock rate; a tiny
# non-zero activity does not change that. When GCLK toggles (window 0..end)
# the real rate is used (gated flop ~1/10 of a flop on S_AXI_ACLK). So for a
# clock-gated variant a window with the gates closed throughout gives an upper
# bound. Deleting the clock instead (all activity from the VCD) was tried and
# dropped: without a clock the switching power came out 1e-8 of the normal value.
# env: SHELL_FINAL (results/final of a gemm_axi_shell run), OUT (report prefix),
#      ACT (optional)
set R $::env(SHELL_FINAL)
set lib $::env(PDK_ROOT)/sky130A/libs.ref
read_liberty $lib/sky130_fd_sc_hd/lib/sky130_fd_sc_hd__tt_025C_1v80.lib
read_verilog $R/verilog/gl/GemmAxiShell.nl.v
link_design GemmAxiShell
read_sdc $R/sdc/GemmAxiShell.sdc
read_spef $R/spef/GemmAxiShell.spef
if {[info exists ::env(ACT)]} {
    set f [open $::env(ACT)]; set ncyc 0; set np 0; set nport 0; set nmiss 0
    while {[gets $f line] >= 0} {
        if {[string index $line 0] eq "#"} {
            set ncyc [lindex $line 2]; continue
        }
        lassign $line kind name tog duty
        # transitions per clock cycle (OpenSTA divides by the clock period)
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
}
report_power
report_power -digits 6 > $::env(OUT).design.rpt
