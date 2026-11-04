# Seed for the first IP run (only if run_flow.sh did not write clk_latency.tcl):
# median clock latency of the core_v11 flops (tools/clock_latency.py, 5.16 ns).
# run_flow.sh ip-pre / ip write clk_latency.tcl = that + the AXI macro's own
# latency, since every port of the IP faces a flop inside the macro.
set ::env(GEMM_CLK_LAT_MIN) 5.16
set ::env(GEMM_CLK_LAT_MAX) 5.16
