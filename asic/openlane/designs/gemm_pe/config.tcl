# ---------------------------------------------------------------------------
# Level 0 - one ProcessingElement, flat. A MEASUREMENT run, not a macro:
# it gives the real cell area (synth_cell_count, area in the synthesis
# report) and slack that size the row macro. A few minutes, < 1 GB RAM.
#   ./flow.tcl -design gemm_pe -tag pe_v1 -overwrite
# ---------------------------------------------------------------------------
source $::env(DESIGN_DIR)/../gemm_common.tcl

set ::env(DESIGN_NAME)   "ProcessingElement"
set ::env(VERILOG_FILES) [list $::env(DESIGN_DIR)/src/PE.v]

# PE.v does not read gemm_asic_cfg.vh, so pass the reset choice as a parameter
set ::env(SYNTH_PARAMETERS) "P_DATAPATH_RESET=$::env(GEMM_DP_RESET)"

# build it under the same conditions as inside the row macro
set ::env(DESIGN_IS_CORE)   0
set ::env(FP_PDN_CORE_RING) 0
set ::env(RT_MAX_LAYER)     "met4"

set ::env(FP_SIZING)         relative
set ::env(FP_CORE_UTIL)      50
set ::env(PL_TARGET_DENSITY) 0.60
