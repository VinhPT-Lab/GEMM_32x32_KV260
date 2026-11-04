# ---------------------------------------------------------------------------
# ip_post_cts.sdc - the post-CTS SDC of gemm_ip rebuilt from ip.sdc at the
# current CLOCK_PERIOD: ip.sdc (core.sdc: clock, I/O delays from IO_PCT and
# clk_latency.tcl, derate, cfg_shift multicycle) + the propagated clock that
# CTS adds to the SDC it writes. Used by ip_resume.tcl when the clock period
# differs from the one in the saved post-CTS SDC (written at the CTS period).
# ---------------------------------------------------------------------------
source $::env(DESIGN_DIR)/ip.sdc
set_propagated_clock [all_clocks]
