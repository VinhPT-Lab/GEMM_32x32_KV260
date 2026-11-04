#!/usr/bin/env python3
"""vcd_window.py <c0> <c1> <vcd out> <module .v out>
Verilog module for run_gls.sh (EXTRA_V): dumps the nets of the core scope and of
the 32 row scopes (depth 1, no cell internals) for testbench cycles [c0, c1), then stops."""
import sys
c0, c1, vcd, out = sys.argv[1:5]
tb = "tb_GEMM_top_axi_two_job_64x64_verify_copy_matrix"
top = f"{tb}.dut.u_gemm_accelerator"
rows = "\n".join(f"        $dumpvars(1, {top}.\\u_buffer_feeder.u_compute_core.u_processing_element_array.g_pe_row[{i}].u_row );"
                 for i in range(32))
open(out, "w").write(f"""`timescale 1ns / 1ps
module vcd_window;
    initial begin
        $dumpfile("{vcd}");
        wait ({tb}.cycle == {c0});
        @(negedge {tb}.clk);
        $dumpvars(1, {top});
{rows}
        $display("VCD_START cycle=%0d t=%0t", {tb}.cycle, $time);
        wait ({tb}.cycle == {c1});
        @(negedge {tb}.clk);
        $display("VCD_END cycle=%0d t=%0t", {tb}.cycle, $time);
        $dumpflush;
        $finish;
    end
endmodule
""")
