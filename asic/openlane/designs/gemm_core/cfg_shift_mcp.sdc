# ---------------------------------------------------------------------------
# cfg_shift multicycle - r_cfg_shift is a quasi-static configuration register.
#
# GEMM_core loads r_cfg_shift only while ~w_core_active_for_config, i.e. while
# no input is being accepted, nothing is buffered or computing and no result
# is valid. Its only loads are the 32 RightShifters of Out_buffer, whose
# outputs go to o_result_data, captured only on r_output_mem_valid_d2 &
# i_result_ready - a whole GEMM job (dozens of cycles) after r_cfg_shift last
# changed. So r_cfg_shift -> shifter -> o_result_data gets 4 cycles for setup,
# and the hold check stays at the launch edge (hold 3 = setup 4 - 1).
# The input path i_cfg_shift -> r_cfg_shift is NOT covered (the top-level port
# net has no "." in its name).
#
# In the flat netlist each bit keeps one of its names: r_cfg_shift[b],
# u_output_buffer.i_cfg_shift[b] or ...u_right_shifter.i_shift_amount[b];
# all three are looked up. Wrapped in catch: whatever happens here, the SDC
# still reads (worst case: the constraint is not applied and the log says so).
# Sourced at the end of core.sdc; appended by hand to the post-CTS SDC of
# runs that were placed before it existed (core_v6r).
# ---------------------------------------------------------------------------
if { [catch {
    set gemm_mcp_nets {}
    foreach gemm_pat {r_cfg_shift* *.i_cfg_shift* *i_shift_amount*} {
        if { ![catch {get_nets $gemm_pat} gemm_found] } {
            set gemm_mcp_nets [concat $gemm_mcp_nets $gemm_found]
        }
    }
    if { [llength $gemm_mcp_nets] > 0 } {
        set_multicycle_path -setup 4 -through $gemm_mcp_nets
        set_multicycle_path -hold 3 -through $gemm_mcp_nets
        puts "\[INFO\]: cfg_shift multicycle (setup 4 / hold 3) through [llength $gemm_mcp_nets] nets"
    } else {
        puts "\[WARNING\]: cfg_shift multicycle: no r_cfg_shift net found, not applied"
    }
} gemm_err] } {
    puts "\[WARNING\]: cfg_shift multicycle not applied: $gemm_err"
}
