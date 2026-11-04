# Static IR drop INSIDE one ProcessingElementRow (row_v1), OpenROAD PSM of OpenLane 1.0.2
# (41a51eaf), TT, 50 MHz. Instance power: the row's own cells with the VCD activity of row 0
# in the compute phase of the 64x64x64 job (job_power.sh, IP-level GLS), row netlist + SPEF.
# Voltage sources: the row's vccd1 / vssd1 pins of its LEF (4 + 4 met4 stripes), one source
# at the centre of each stripe (VSRC files: x y size voltage). The drop is relative to the
# row's pins, i.e. it adds to the drop of the IP grid at those pins.
# env: ACT, OUT, VSRC_DIR, PDK_ROOT
set pdk $::env(PDK_ROOT)/sky130A/libs.ref/sky130_fd_sc_hd
set R ${OL}/designs/gemm_row/runs/row_v1/results/final
read_lef $pdk/techlef/sky130_fd_sc_hd__nom.tlef
read_lef $pdk/lef/sky130_fd_sc_hd.lef
read_lef $pdk/lef/sky130_ef_sc_hd.lef
read_def $R/def/ProcessingElementRow.def
read_liberty $pdk/lib/sky130_fd_sc_hd__tt_025C_1v80.lib
read_sdc $R/sdc/ProcessingElementRow.sdc
create_clock -name i_clk -period 20 [get_ports i_clk]
set_propagated_clock [all_clocks]
read_spef $R/spef/ProcessingElementRow.spef
set f [open $::env(ACT)]; set np 0
while {[gets $f line] >= 0} {
    if {[string index $line 0] eq "#"} { set ncyc [lindex $line 2]; continue }
    lassign $line kind name tog duty
    set pin [sta::find_pin $name]
    if {$pin eq "NULL" || $pin eq ""} { continue }
    if {[sta::is_clock_src $pin]} { continue }
    sta::set_power_pin_activity $pin [expr {double($tog) / $ncyc}] $duty; incr np
}
close $f
puts "IRROW activity on $np pins over $ncyc cycles"
report_power
foreach {net v} {vccd1 1.8 vssd1 0.0} {
    set_pdnsim_net_voltage -net $net -voltage $v
    analyze_power_grid -net $net -vsrc $::env(VSRC_DIR)/$net.vsrc -outfile $::env(OUT).$net.ir.csv
    puts "IRROW done $net"
}
