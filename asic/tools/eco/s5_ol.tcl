# Step 5: bring an ECO layout (DEF written by OpenROAD dcf3613) back into
# OpenLane 1.0.2 and check it there. Run directory under
# $ECO_DIR/s5/<S5_TAG>, nothing under designs/gemm_ip/runs.
#   S5_DEF   DEF to import
#   S5_TAG   run tag
#   S5_MODE  arc  = import (DEF, ODB, netlist, powered netlist) + ARC antenna check
#            full = arc + Magic GDS + Magic DRC (full std-cell views) + SPICE export + LVS
#            lvs  = arc + SPICE export (from LEF) + LVS
#            final = rcx + full (RCX/STA, Magic GDS + DRC, SPICE + LVS) in one run
#            S5_KLAYOUT=1 adds KLayout GDS + XOR after LVS (full / final)
#            rcx  = arc + run_parasitics_sta (RCX min/max/nom, multi-corner STA) with the final SDC
package require openlane
prep -design gemm_ip -tag $::env(S5_TAG) -run_path $::env(ECO_DIR)/s5 -overwrite
# Power nets as the floorplan step sets them (copied from designs/gemm_ip/ip_resume.tcl):
# this script skips the floorplan, and without them write_powered_def looks for
# VPWR / VGND top-level ports and OpenLane's `write` does no global connect.
if { [info exists ::env(VDD_NETS)] && [info exists ::env(GND_NETS)] } {
    set ::env(VDD_PIN) [lindex $::env(VDD_NETS) 0]
    set ::env(GND_PIN) [lindex $::env(GND_NETS) 0]
}
foreach {net pin} {VDD_NET VDD_PIN GND_NET GND_PIN} {
    if { ![info exists ::env($net)] && [info exists ::env($pin)] } { set ::env($net) $::env($pin) }
}
puts_info "probe: power nets $::env(VDD_NET)/$::env(GND_NET), pins $::env(VDD_PIN)/$::env(GND_PIN)"

# import: read MERGED_LEF + the DEF (io.tcl IO_READ_DEF), write every view
set ::env(IO_READ_DEF) 1
set_def $::env(S5_DEF)
run_openroad_script $::env(SCRIPTS_DIR)/openroad/write_views.tcl \
    -indexed_log [index_file $::env(routing_logs)/eco_import.log] \
    -save "to=$::env(routing_results),noindex,def,odb,netlist,powered_netlist"
set ::env(IO_READ_DEF) 0
puts_info "probe: imported $::env(S5_DEF) -> $::env(CURRENT_ODB)"

run_antenna_check
set n -1
if { [info exists ::env(ANTENNA_VIOLATOR_LIST)] } {
    set n [exec sh -c "grep -c 'Pin:' $::env(ANTENNA_VIOLATOR_LIST) || true"]
}
puts_info "probe: ARC antenna violating pins: $n"

if { $::env(S5_MODE) eq "rcx" || $::env(S5_MODE) eq "final" } {
    # signoff RC extraction (min / max / nom) + multi-corner STA as OL1's signoff,
    # with the final standalone SDC of ip_v3r
    set ::env(CURRENT_SDC) $::env(ECO_DIR)/in/GEMM_top.sdc
    set ::env(RCX_SDC_FILE) $::env(ECO_DIR)/in/GEMM_top.sdc
    run_parasitics_sta
    puts_info "probe: RCX + STA done"
}
if { $::env(S5_MODE) eq "lvs" } {
    set ::env(EXIT_ON_ERROR) 0
    if { [catch { run_magic_spice_export; run_lvs } e] } {
        puts_err "probe: LVS FAIL or did not finish ($e)"
    }
    set ::env(EXIT_ON_ERROR) 1
}
if { $::env(S5_MODE) eq "full" || $::env(S5_MODE) eq "final" } {
    run_magic
    # Same as gemm_magic_drc of designs/gemm_ip/ip_route_signoff.tcl (copied here,
    # that file runs the whole flow when sourced): MAGTYPE mag, standard cells full.
    increment_index
    set log [index_file $::env(signoff_logs)/drc.log]
    puts_info "Running Magic DRC, full standard-cell views (log: [relpath . $log])..."
    set ::env(drc_prefix) $::env(signoff_reports)/drc
    set ::env(MAGTYPE) mag
    run_magic_script $::env(SCRIPTS_DIR)/magic/drc.tcl -indexed_log $log
    try_exec python3 $::env(SCRIPTS_DIR)/drc_rosetta.py magic to_tr \
        -o $::env(drc_prefix).tr $::env(drc_prefix).rpt
    save_final_views
    set ::env(EXIT_ON_ERROR) 0
    if { [catch { run_magic_spice_export; run_lvs } e] } {
        puts_err "probe: LVS FAIL or did not finish ($e)"
    }
    set ::env(EXIT_ON_ERROR) 1
    save_final_views
    # KLayout stream-out + XOR against the Magic GDS (off in the gemm configs as slow
    # on this die, back on for signoff); last, so a slow or failed XOR loses nothing
    if { [info exists ::env(S5_KLAYOUT)] && $::env(S5_KLAYOUT) } {
        set ::env(RUN_KLAYOUT_XOR) 1
        set ::env(EXIT_ON_ERROR) 0
        if { [catch { run_klayout } e] } { puts_err "probe: KLayout GDS did not finish ($e)" }
        if { [catch { run_klayout_gds_xor } e] } { puts_err "probe: KLayout XOR did not finish ($e)" }
        set ::env(EXIT_ON_ERROR) 1
    }
}
puts_info "probe: step 5 ($::env(S5_MODE)) done"
