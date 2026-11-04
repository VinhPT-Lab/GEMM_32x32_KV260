`timescale 1ns / 1ps
// ---------------------------------------------------------------------------
// FeatureSkew: row i of the feature vector is delayed by PE_LATENCY*i cycles.
// This logic used to sit inside ProcessingElementArray next to each row
// instance; that made every row different. Pulled out here so all rows are
// identical and can share one hard macro. Behaviour is unchanged.
// ---------------------------------------------------------------------------
module FeatureSkew
#(
    parameter integer P_DATA_WIDTH     = 8,
    parameter integer P_ARRAY_ROWS     = 32,
    parameter integer P_PE_LATENCY     = 2,
    parameter integer P_RESET          = 1
)
(
    input                                  i_clk,
    input                                  i_rst_n,
    input  [P_DATA_WIDTH*P_ARRAY_ROWS-1:0] i_feature_vector,
    output [P_DATA_WIDTH*P_ARRAY_ROWS-1:0] o_feature_vector
);
genvar i;
generate
    for (i = 0; i < P_ARRAY_ROWS; i = i + 1) begin : g_row_skew
        DelayLine #(
            .P_WIDTH (P_DATA_WIDTH),
            .P_DEPTH (P_PE_LATENCY*i),
            .P_RESET (P_RESET)
        ) u_delay (
            .i_clk   (i_clk),
            .i_rst_n (i_rst_n),
            .i_data  (i_feature_vector[P_DATA_WIDTH*i +: P_DATA_WIDTH]),
            .o_data  (o_feature_vector[P_DATA_WIDTH*i +: P_DATA_WIDTH])
        );
    end
endgenerate
endmodule
