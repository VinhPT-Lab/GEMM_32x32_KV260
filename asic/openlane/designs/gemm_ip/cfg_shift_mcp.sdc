# ---------------------------------------------------------------------------
# cfg_shift multicycle of the IP - same constraint as gemm_core/cfg_shift_mcp.sdc
# (r_cfg_shift -> RightShifter -> result data: 4 cycles setup, hold 3), with
# the names of the flat IP netlist:
#   - r_cfg_shift is still the core's register, now u_gemm_accelerator.r_cfg_shift;
#   - its input comes from the AXI macro pin u_axi_shell/o_cfg_shift (net
#     w_cfg_shift or u_gemm_accelerator.i_cfg_shift after flattening). That
#     input path is single-cycle and is NOT covered: no pattern below matches
#     the net between the macro pin and r_cfg_shift;
#   - the result end is now the macro pin u_axi_shell/i_result_data (the result
#     skid buffer inside the macro), no longer a port of the block.
# Each bit of r_cfg_shift keeps one of these names in the flat netlist:
# u_gemm_accelerator.r_cfg_shift[b], u_gemm_accelerator.u_output_buffer.i_cfg_shift[b]
# or ...u_right_shifter.i_shift_amount[b]; all are looked up.
# ---------------------------------------------------------------------------
if { [catch {
    set gemm_mcp_nets {}
    foreach gemm_pat {u_gemm_accelerator.r_cfg_shift* u_gemm_accelerator.u_output_buffer.i_cfg_shift*
                      u_gemm_accelerator.*i_shift_amount*} {
        if { ![catch {get_nets $gemm_pat} gemm_found] } {
            set gemm_mcp_nets [concat $gemm_mcp_nets $gemm_found]
        }
    }
    if { [llength $gemm_mcp_nets] > 0 } {
        set_multicycle_path -setup 4 -through $gemm_mcp_nets
        set_multicycle_path -hold 3 -through $gemm_mcp_nets
        puts "\[INFO\]: cfg_shift multicycle (setup 4 / hold 3) through [llength $gemm_mcp_nets] nets"
    } else {
        puts "\[WARNING\]: cfg_shift multicycle: no u_gemm_accelerator.r_cfg_shift net found, not applied"
    }
} gemm_err] } {
    puts "\[WARNING\]: cfg_shift multicycle not applied: $gemm_err"
}
