#!/usr/bin/env python3
"""vcd_job_ip.py <c0> <c1> <vcd out|-> <module .v out> [gl|rtl]
Verilog module for sim/run_ip_gls.sh (EXTRA_V) or the RTL perf runs:
  - FSM monitor: prints 'FSM_STATE cycle=C state=S' whenever the BufferFeeder state
    (IDLE 0, SET_WEIGHT 1, SET_FEATURE 3) changes. It is sampled at the posedge with the
    testbench cycle counter before its update, the same convention as the testbench
    *_ACCEPT lines: the line labels the cycle whose handshakes that posedge samples.
  - with a VCD file: dumps the nets (depth 1) of the IP top, the 32 rows and the AXI shell
    for testbench cycles c0+1 .. c1 (dump starts at the negedge where cycle == c0 and
    stops at the negedge where cycle == c1 + 1), then ends the simulation.
Window for one whole job: c0 = JOB_START - 1, c1 = last RESULT_ACCEPT cycle of that job."""
import sys
c0, c1, vcd, out = sys.argv[1:5]
mode = sys.argv[5] if len(sys.argv) > 5 else "gl"
tb = "tb_GEMM_top_axi_two_job_64x64_verify_copy_matrix"
top = f"{tb}.dut"
if mode == "gl":
    st = (f"{{{top}.\\u_gemm_accelerator.u_buffer_feeder.state[1] , "
          f"{top}.\\u_gemm_accelerator.u_buffer_feeder.state[0] }}")
else:
    st = f"{top}.u_gemm_accelerator.u_buffer_feeder.state"
mon = f"""    reg [1:0] st_q = 2'b00;
    wire [1:0] st = {st};
    always @(posedge {tb}.clk) begin
        if (st !== st_q) $display("FSM_STATE cycle=%0d state=%0d", {tb}.cycle, st);
        st_q <= st;
    end
"""
dump = ""
if vcd != "-":
    rows = "\n".join(f"        $dumpvars(1, {top}.\\u_gemm_accelerator.u_buffer_feeder.u_compute_core.u_processing_element_array.g_pe_row[{i}].u_row );"
                     for i in range(32))
    dump = f"""    initial begin
        $dumpfile("{vcd}");
        wait ({tb}.cycle == {c0});
        @(negedge {tb}.clk);
        $dumpvars(1, {top});
{rows}
        $dumpvars(1, {top}.u_axi_shell);
        $display("VCD_START cycle=%0d t=%0t", {tb}.cycle, $time);
        wait ({tb}.cycle == {int(c1) + 1});
        @(negedge {tb}.clk);
        $display("VCD_END cycle=%0d t=%0t", {tb}.cycle, $time);
        $dumpflush;
        $finish;
    end
"""
open(out, "w").write(f"""`timescale 1ns / 1ps
module vcd_job;
{mon}{dump}endmodule
""")
