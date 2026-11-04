`timescale 1ns / 1ps
// ---------------------------------------------------------------------------
// OutputDeskew: column i of the bottom-row partial sums is delayed by
// (P_ARRAY_COLS-1-i) cycles so all columns line up. Same logic as the
// g_align_output_column block of the original ProcessingElementArray.
// ---------------------------------------------------------------------------
module OutputDeskew
#(
    parameter integer P_PSUM_WIDTH = 21,
    parameter integer P_ARRAY_COLS = 32,
    parameter integer P_RESET      = 1
)
(
    input                                  i_clk,
    input                                  i_rst_n,
    input  [P_PSUM_WIDTH*P_ARRAY_COLS-1:0] i_partial_sum_vector,
    output [P_PSUM_WIDTH*P_ARRAY_COLS-1:0] o_partial_sum_vector
);
genvar i;
generate
    for (i = 0; i < P_ARRAY_COLS; i = i + 1) begin : g_col_deskew
        DelayLine #(
            .P_WIDTH (P_PSUM_WIDTH),
            .P_DEPTH (P_ARRAY_COLS-1-i),
            .P_RESET (P_RESET)
        ) u_delay (
            .i_clk   (i_clk),
            .i_rst_n (i_rst_n),
            .i_data  (i_partial_sum_vector[P_PSUM_WIDTH*i +: P_PSUM_WIDTH]),
            .o_data  (o_partial_sum_vector[P_PSUM_WIDTH*i +: P_PSUM_WIDTH])
        );
    end
endgenerate
endmodule
