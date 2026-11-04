`timescale 1ns / 1ps
// ---------------------------------------------------------------------------
// DelayLine: P_DEPTH-stage register pipeline, P_WIDTH bits wide.
// P_DEPTH = 0 is a plain wire. Used by FeatureSkew and OutputDeskew.
// ---------------------------------------------------------------------------
module DelayLine
#(
    parameter integer P_WIDTH = 8,
    parameter integer P_DEPTH = 1,
    parameter integer P_RESET = 1
)
(
    input                i_clk,
    input                i_rst_n,
    input  [P_WIDTH-1:0] i_data,
    output [P_WIDTH-1:0] o_data
);
generate
    if (P_DEPTH == 0) begin : g_wire
        assign o_data = i_data;
    end
    else begin : g_regs
        reg [P_WIDTH*P_DEPTH-1:0] r_pipe;   // stage k lives in bits [k*W +: W]
        if (P_DEPTH == 1) begin : g_d1
            if (P_RESET) begin : g_r
                always @(posedge i_clk or negedge i_rst_n)
                    if (~i_rst_n) r_pipe <= 0;
                    else          r_pipe <= i_data;
            end else begin : g_nr
                always @(posedge i_clk) r_pipe <= i_data;
            end
        end
        else begin : g_dn
            if (P_RESET) begin : g_r
                always @(posedge i_clk or negedge i_rst_n)
                    if (~i_rst_n) r_pipe <= 0;
                    else          r_pipe <= {r_pipe[P_WIDTH*(P_DEPTH-1)-1:0], i_data};
            end else begin : g_nr
                always @(posedge i_clk)
                    r_pipe <= {r_pipe[P_WIDTH*(P_DEPTH-1)-1:0], i_data};
            end
        end
        assign o_data = r_pipe[P_WIDTH*(P_DEPTH-1) +: P_WIDTH];
    end
endgenerate
endmodule
