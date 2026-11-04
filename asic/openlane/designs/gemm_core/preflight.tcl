# ---------------------------------------------------------------------------
# preflight.tcl - lint + synthesis + floorplan of gemm_core only (~1 h instead
# of the full run). Catches the expensive mistakes early: missing macro views,
# memories that slipped through as flip-flops, macro names that do not match
# macro.cfg, PDN connectivity (PSM-0069), I/O placement.
# Started by run_flow.sh core-pre through OpenLane's interactive mode:
#   make -C $OL quick_run QUICK_RUN_DESIGN="gemm_core -it -file designs/gemm_core/preflight.tcl"
# ---------------------------------------------------------------------------
package require openlane;   # 1.0.x module from scripts/ (TCL8_5_TM_PATH set by flow.tcl)
prep -design gemm_core -tag core_pre -overwrite
run_verilator
run_synthesis
run_floorplan
puts "\[INFO\]: GEMM_CORE_PREFLIGHT_DONE"
