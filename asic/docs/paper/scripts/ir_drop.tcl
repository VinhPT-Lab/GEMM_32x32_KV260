# Static IR drop of the final IP (OpenROAD PSM of OpenLane 1.0.2, 41a51eaf), TT, 50 MHz.
# Power per instance: top-level standard cells from a VCD activity file (ACT; the paper run
# uses the compute phase of the 64x64x64 job, job_power.sh), SRAM from the OpenRAM lib,
# rows and AXI shell as constant power equal to their VCD average (IRLIB/*.irmodel.lib).
# Voltage sources: without VSRC, PSM's default checkerboard of bumps (140 um pitch) over the
# core; with VSRC=<prefix>, the files <prefix>.<net>.vsrc (x,y,size,voltage per line, um).
# Run with -gui (offscreen) to also save the heatmap images.
# env: ODB, SDC, SPEF, ACT, OUT (prefix), IRLIB (dir of the model libs), VSRC (optional)
set lib $::env(PDK_ROOT)/sky130A/libs.ref
read_db $::env(ODB)
read_liberty $lib/sky130_fd_sc_hd/lib/sky130_fd_sc_hd__tt_025C_1v80.lib
read_liberty $lib/sky130_sram_macros/lib/sky130_sram_2kbyte_1rw1r_32x512_8_TT_1p8V_25C.lib
read_liberty $::env(IRLIB)/ProcessingElementRow.irmodel.lib
read_liberty $::env(IRLIB)/GemmAxiShell.irmodel.lib
read_sdc $::env(SDC)
set_propagated_clock [all_clocks]
read_spef $::env(SPEF)
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
puts "IRDROP activity: $np top-level driver pins set, $nmiss not in the top level (inside rows / shell)"
report_power
foreach {net v} {vccd1 1.8 vssd1 0.0} {
    set_pdnsim_net_voltage -net $net -voltage $v
    if {[info exists ::env(VSRC)]} {
        analyze_power_grid -net $net -vsrc $::env(VSRC).$net.vsrc -outfile $::env(OUT).$net.ir.csv
    } else {
        analyze_power_grid -net $net -outfile $::env(OUT).$net.ir.csv
    }
    puts "IRDROP done $net"
    # the IR Drop heatmap shows the last analysed net; one image per net, layer met1
    if {[info commands gui::enabled] ne "" && [gui::enabled] && [catch {
        gui::set_display_controls "*" visible false
        gui::set_display_controls "Heat Maps/IR Drop" visible true
        gui::set_heatmap IRDrop Layer met1
        gui::set_heatmap IRDrop ShowLegend 1
        gui::set_heatmap IRDrop rebuild
        gui::fit
        save_image -resolution 5 $::env(OUT).$net.irdrop.png
        gui::set_display_controls "Heat Maps/IR Drop" visible false
    } err]} { puts "IRDROP image failed for $net: $err" }
}
puts "IRDROP finished"
