#!/usr/bin/env python3
"""vcd_window_ip.py <c0> <c1> <vcd out> <module .v out>
Verilog module for sim/run_ip_gls.sh (EXTRA_V): dumps the nets (depth 1, no cell
internals) of the IP top scope (flat core), of the 32 row scopes and of the AXI shell
scope for testbench cycles [c0, c1), then stops the simulation.
Same scheme as tools/power/vcd_window.py of the core."""
import sys
c0, c1, vcd, out = sys.argv[1:5]
tb = "tb_GEMM_top_axi_two_job_64x64_verify_copy_matrix"
top = f"{tb}.dut"
rows = "\n".join(f"        $dumpvars(1, {top}.\\u_gemm_accelerator.u_buffer_feeder.u_compute_core.u_processing_element_array.g_pe_row[{i}].u_row );"
                 for i in range(32))
open(out, "w").write(f"""`timescale 1ns / 1ps
module vcd_window;
    initial begin
        $dumpfile("{vcd}");
        wait ({tb}.cycle == {c0});
        @(negedge {tb}.clk);
        $dumpvars(1, {top});
{rows}
        $dumpvars(1, {top}.u_axi_shell);
        $display("VCD_START cycle=%0d t=%0t", {tb}.cycle, $time);
        wait ({tb}.cycle == {c1});
        @(negedge {tb}.clk);
        $display("VCD_END cycle=%0d t=%0t", {tb}.cycle, $time);
        $dumpflush;
        $finish;
    end
endmodule
""")
