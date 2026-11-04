# Leakage of the IP per standard-cell corner (LIBCORNER = tt | ff | ss); based on tools/power/power.tcl.
# Power of the core at the typical corner (run inside the OpenLane image with sta).
# Rows are read as their gate netlist + SPEF (not the row .lib), so their cells count.
# env: CORE_FINAL, ROW_FINAL (results/final of the core / row run, container paths),
#      DESIGN (top module, default GemmAccelerator; GEMM_top for the complete IP),
#      SHELL_FINAL (optional, results/final of the AXI macro run: gate netlist + SPEF),
#      OUT (prefix of the reports), ACT (optional, activity file from vcd2act.py)
set R $::env(CORE_FINAL)
set W $::env(ROW_FINAL)
set D [expr {[info exists ::env(DESIGN)] ? $::env(DESIGN) : "GemmAccelerator"}]
set lib $::env(PDK_ROOT)/sky130A/libs.ref
array set LIBC {tt tt_025C_1v80 ff ff_n40C_1v95 ss ss_100C_1v60}
read_liberty $lib/sky130_fd_sc_hd/lib/sky130_fd_sc_hd__$LIBC($::env(LIBCORNER)).lib
read_liberty $lib/sky130_sram_macros/lib/sky130_sram_2kbyte_1rw1r_32x512_8_TT_1p8V_25C.lib
read_verilog $W/verilog/gl/ProcessingElementRow.nl.v
if {[info exists ::env(SHELL_FINAL)]} { read_verilog $::env(SHELL_FINAL)/verilog/gl/GemmAxiShell.nl.v }
read_verilog $R/verilog/gl/$D.nl.v
link_design $D
read_sdc $R/sdc/$D.sdc
read_spef $R/spef/$D.spef
foreach r [get_cells -hierarchical *g_pe_row*u_row] {
    read_spef -path [get_full_name $r] $W/spef/ProcessingElementRow.spef
}
if {[info exists ::env(SHELL_FINAL)]} {
    foreach r [get_cells -hierarchical u_axi_shell] {
        read_spef -path [get_full_name $r] $::env(SHELL_FINAL)/spef/GemmAxiShell.spef
    }
}
if {[info exists ::env(ACT)]} {
    # read_power_activities of this OpenSTA only matches VCD names to pins, so the
    # activity of every net comes from vcd2act.py and is set on its driver pin
    set f [open $::env(ACT)]; set ncyc 0; set np 0; set nmiss 0
    while {[gets $f line] >= 0} {
        if {[string index $line 0] eq "#"} { set ncyc [lindex $line 2]; continue }
        lassign $line kind name tog duty
        if {$kind ne "pin"} { continue }
        set pin [sta::find_pin $name]
        if {$pin eq "NULL" || $pin eq ""} { incr nmiss; continue }
        if {[sta::is_clock_src $pin]} { continue }
        sta::set_power_pin_activity $pin [expr {double($tog) / $ncyc}] $duty
        incr np
    }
    close $f
    puts "activity from [file tail $::env(ACT)]: $np driver pins over $ncyc cycles, $nmiss not found"
}
# leakage only: OpenSTA default activity, standard cells at LIBCORNER (SRAM: TT lib only)
report_power -digits 6 > $::env(OUT).design.rpt
set leaf [list]
foreach c [get_cells -hierarchical *] {
    set ref [get_property $c ref_name]
    if {[string match sky130* $ref] && ![regexp {__(fill|decap|tapvpwrvgnd)} $ref]} { lappend leaf $c }
}
set f [open $::env(OUT).refs.txt w]
foreach c $leaf { puts $f "[get_full_name $c] [get_property $c ref_name]" }
close $f
report_power -instances $leaf -digits 8 > $::env(OUT).inst.rpt
