# ---------------------------------------------------------------------------
# Shared settings for gemm_pe / gemm_row / gemm_array (OpenLane v1.0.2).
# Sourced by each config.tcl. Change a value here, not in three places.
# ---------------------------------------------------------------------------

# 0 = no async reset on datapath flops (PE feature/product/psum, skew/deskew).
#     Resettable flops in the array: ~92k -> ~16k. Valid results unchanged;
#     prove it first with sim/run_equiv.sh (it tests both settings).
# 1 = exactly like the FPGA RTL.
set ::env(GEMM_DP_RESET) 0

set ::env(CLOCK_PORT)   "i_clk"
set ::env(CLOCK_NET)    "i_clk"
set ::env(CLOCK_PERIOD) 10

# same power net names at every level so macro pins match the parent grid
set ::env(VDD_NETS) [list {vccd1}]
set ::env(GND_NETS) [list {vssd1}]

# i7-14700HX has 28 threads; detailed routing memory grows with threads.
# 12 is a safe middle for 16 GB. Raise it for the small designs if you like.
set ::env(ROUTING_CORES) 12

# rows of the array are identical copies; keep the width tables in sync
set ::env(GEMM_N)   32
set ::env(GEMM_DW)  8
set ::env(GEMM_RIW) 5
