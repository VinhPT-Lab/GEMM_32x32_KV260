# Seed for the first core run: typical flop clock latency measured on the
# array (array_v1_PASS: 2.98 / 4.16 / 5.96 ns). run_flow.sh overwrites this
# with the core's own number after every core run (tools/clock_latency.py).
set ::env(GEMM_CLK_LAT_MIN) 4.16
set ::env(GEMM_CLK_LAT_MAX) 4.16
