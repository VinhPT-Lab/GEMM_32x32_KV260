# ---------------------------------------------------------------------------
# ip_write_sdc.tcl - write the SDC that ip_post_cts.sdc builds as one
# self-contained file (write_sdc: no source, no ::env), so the final views
# (results/final/sdc) can be read without DESIGN_DIR: tools/power.sh,
# tools/timing_gate.py (create_clock -period), any STA outside OpenLane.
# Run by ip_resume.tcl (run_openroad_script -save sdc) after the rebuild.
# ---------------------------------------------------------------------------
source $::env(SCRIPTS_DIR)/openroad/common/io.tcl
read -no_spefs
write
