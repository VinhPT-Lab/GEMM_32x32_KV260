# Headless OpenROAD (OpenLane 1.0.2, 41a51eaf) images of the final layout: placement density,
# routing congestion estimate, clock tree. Run: QT_QPA_PLATFORM=offscreen openroad -gui -exit
# env: ODB, SDC, SPEF, OUT (prefix)
set lib $::env(PDK_ROOT)/sky130A/libs.ref
read_db $::env(ODB)
read_liberty $lib/sky130_fd_sc_hd/lib/sky130_fd_sc_hd__tt_025C_1v80.lib
read_liberty $lib/sky130_sram_macros/lib/sky130_sram_2kbyte_1rw1r_32x512_8_TT_1p8V_25C.lib
read_liberty ${ECO_DIR}/lib/ProcessingElementRow.lib
read_liberty ${ECO_DIR}/lib/GemmAxiShell.lib
read_sdc $::env(SDC)
set_propagated_clock [all_clocks]
read_spef $::env(SPEF)
gui::fit
if {![info exists ::env(NO_LAYOUT)]} { save_image -resolution 5 $::env(OUT).layout.png }
gui::set_display_controls "*" visible false
gui::set_display_controls "Instances/*" visible true
# heat maps of this version: Placement, Power, Routing (needs global route data), IRDrop
foreach hm [expr {[info exists ::env(HEATMAPS)] ? $::env(HEATMAPS) : "Placement"}] {
    if {[catch {
        gui::set_display_controls "Heat Maps/*" visible false
        gui::set_heatmap $hm rebuild
        gui::set_display_controls "Heat Maps/$hm*" visible true
        gui::fit
        save_image -resolution 5 $::env(OUT).heatmap_$hm.png
        gui::dump_heatmap $hm $::env(OUT).heatmap_$hm.csv
        puts "SHOT heatmap $hm"
    } err]} { puts "SHOT heatmap $hm not available: $err" }
}
if {[catch { gui::save_clocktree_image $::env(OUT).clocktree.png S_AXI_ACLK; puts "SHOT clocktree" } err]} {
    puts "SHOT clocktree failed: $err"
}
