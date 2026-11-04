`timescale 1ns / 1ps
// ---------------------------------------------------------------------------
// ResetSync: asynchronous assert, synchronous de-assert.
// On the KV260 the proc_sys_reset IP did this for you. On an ASIC nobody
// does, so put one of these between the reset pad/port and every i_rst_n in
// the design (one instance per clock domain - here there is only one).
// ---------------------------------------------------------------------------
module ResetSync
#(
    parameter integer P_STAGES = 2
)
(
    input  i_clk,
    input  i_rst_n_async,
    output o_rst_n_sync
);
reg [P_STAGES-1:0] r_sync;
always @(posedge i_clk or negedge i_rst_n_async) begin
    if (~i_rst_n_async) r_sync <= {P_STAGES{1'b0}};
    else                r_sync <= {r_sync[P_STAGES-2:0], 1'b1};
end
assign o_rst_n_sync = r_sync[P_STAGES-1];
endmodule
