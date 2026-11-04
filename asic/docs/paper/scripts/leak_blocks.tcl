# Leakage of one block of the final IP on its own, standard cells at LIBCORNER (tt | ff | ss).
# BLOCK = row : ProcessingElementRow, row_v1 gate netlist + its SPEF (one row; x32 in the table)
#         axi : GemmAxiShell, ip_shell5 gate netlist + its SPEF
#         top : GEMM_top gate netlist + SPEF with the rows / AXI shell as their abstract .lib
#               (no power in those libs, so this gives the top-level standard cells and the
#               80 SRAMs; SRAM: OpenRAM TT lib, the only corner the PDK ships)
# OpenSTA default activity; only leakage is used. Per-instance report -> <OUT>.inst.rpt
# env: BLOCK, LIBCORNER, ROW_FINAL, SHELL_FINAL, CORE_FINAL, MACRO_LIB (dir of the abstract libs), OUT
set lib $::env(PDK_ROOT)/sky130A/libs.ref
array set LIBC {tt tt_025C_1v80 ff ff_n40C_1v95 ss ss_100C_1v60}
read_liberty $lib/sky130_fd_sc_hd/lib/sky130_fd_sc_hd__$LIBC($::env(LIBCORNER)).lib
switch $::env(BLOCK) {
    row { set R $::env(ROW_FINAL); set D ProcessingElementRow }
    axi { set R $::env(SHELL_FINAL); set D GemmAxiShell }
    top {
        set R $::env(CORE_FINAL); set D GEMM_top
        read_liberty $lib/sky130_sram_macros/lib/sky130_sram_2kbyte_1rw1r_32x512_8_TT_1p8V_25C.lib
        read_liberty $::env(MACRO_LIB)/ProcessingElementRow.lib
        read_liberty $::env(MACRO_LIB)/GemmAxiShell.lib
    }
}
read_verilog $R/verilog/gl/$D.nl.v
link_design $D
if {[file exists $R/sdc/$D.sdc]} { read_sdc $R/sdc/$D.sdc }
read_spef $R/spef/$D.spef
set leaf [list]
foreach c [get_cells *] {
    if {[string match sky130* [get_property $c ref_name]]} { lappend leaf $c }
}
set f [open $::env(OUT).refs.txt w]
foreach c $leaf { puts $f "[get_full_name $c] [get_property $c ref_name]" }
close $f
report_power -digits 6 > $::env(OUT).design.rpt
report_power -instances $leaf -digits 10 > $::env(OUT).inst.rpt
puts "LEAKBLOCK $::env(BLOCK) $::env(LIBCORNER) [llength $leaf] cells"
