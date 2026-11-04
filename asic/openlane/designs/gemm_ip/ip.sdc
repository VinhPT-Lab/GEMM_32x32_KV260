# ---------------------------------------------------------------------------
# ip.sdc - SDC of the complete IP (GEMM_top): gemm_core/core.sdc as it is, with
#   - the clock on S_AXI_ACLK (CLOCK_PORT in config.tcl);
#   - every AXI port with a real outside budget: IO_PCT = GEMM_IP_IO_PCT (0.3,
#     as the shell runs, shell.sdc), no I/O timing waiver at signoff;
#   - port delays measured from the clock arrival of the flops the ports face
#     (GEMM_CLK_LAT_MIN/MAX, clk_latency.tcl): here the flops inside the AXI
#     macro, i.e. the clock at u_axi_shell/S_AXI_ACLK plus the macro's own
#     latency (run_flow.sh ip / ip-pre write clk_latency.tcl);
#   - cfg_shift_mcp.sdc of this directory (r_cfg_shift is inside the core,
#     under u_gemm_accelerator.; its input now comes from a macro pin).
# Plus: S_AXI_ARESETN only feeds ResetSync inside the macro (asynchronous
# assert, synchronised release), as in shell.sdc.
# ---------------------------------------------------------------------------
source $::env(DESIGN_DIR)/../gemm_core/core.sdc
set_false_path -from [get_ports S_AXI_ARESETN]
puts "\[INFO\]: ip.sdc: core.sdc with I/O budget $EXT ns, false path from S_AXI_ARESETN"
