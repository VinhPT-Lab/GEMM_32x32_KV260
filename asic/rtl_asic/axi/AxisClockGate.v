`timescale 1ns / 1ps
// ---------------------------------------------------------------------------
// AxisClockGate - integrated clock gate for one bank of data flops.
//
// o_gclk pulses only in the cycles where i_en is high at the rising edge of
// i_clk. The enable is latched while i_clk is low (latch + AND), so a change
// of i_en during the high phase cannot cut a pulse short: the standard ICG.
//
// Synthesis: the sky130 integrated clock-gating cell (sky130_fd_sc_hd__
// dlclkp_1; dlclkp_4 with GEMM_ICG_X4), so OpenSTA sees a real clock gate (clock-gating checks on i_en)
// and CTS builds the tree up to its CLK pin and on from its GCLK output.
// Simulation: the same latch + AND in behavioural form.
//
// Used by AxisSkidBuffer / AxisFwdSlice when P_CLOCK_GATE = 1: the 258-bit
// data banks then get a clock only when a beat is loaded, instead of every
// cycle. Between bursts (the compute phase of a job) the streams are idle and
// those flops cost no clock power at all.
// ---------------------------------------------------------------------------
module AxisClockGate
(
    input   i_clk,
    input   i_en,
    output  o_gclk
);

`ifdef SYNTHESIS
`ifdef GEMM_ICG_X4
// stronger drive for the GCLK net (gemm_ip_shell: with dlclkp_1 the gated
// branch reached 7.2 ns of latency against ~3 ns for the rest of the macro)
sky130_fd_sc_hd__dlclkp_4 u_icg (
`else
sky130_fd_sc_hd__dlclkp_1 u_icg (
`endif
    .CLK  (i_clk),
    .GATE (i_en),
    .GCLK (o_gclk)
);
`else
reg r_en_latched;
always @(*)
    if (!i_clk)
        r_en_latched = i_en;
assign o_gclk = i_clk & r_en_latched;
`endif

endmodule
