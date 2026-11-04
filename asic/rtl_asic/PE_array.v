`timescale 1ns / 1ps
`include "gemm_asic_cfg.vh"
// ---------------------------------------------------------------------------
// ProcessingElementArray  (ASIC version)
//
//      i_feature_vector ──► FeatureSkew ──► row 0  ◄── psum = 0 enters here
//                                          row 1        │ psum flows down
//                                           ...         ▼
//                                          row N-1 ◄── i_weight_shift_in
//                                            │          (weights flow up)
//                                            ▼
//                                       OutputDeskew ──► o_partial_sum_vector
//
// Port change vs. KV260 version: the 8192-bit i_weight_matrix is replaced by
//   i_weight_shift_en, i_weight_shift_in[N*8], i_weight_load.
// Word k pushed into the chain (k = 0 first) ends up in row k after N shifts,
// which is the same mapping the old weight_buffer[N-1-i] -> row i gave.
// ---------------------------------------------------------------------------
module ProcessingElementArray
#(
    parameter integer P_DATA_WIDTH      = `GEMM_DW,
    parameter integer P_ARRAY_ROWS      = `GEMM_N,
    parameter integer P_ARRAY_COLS      = `GEMM_N,
    parameter integer P_ROW_INDEX_WIDTH = `GEMM_RIW
)
(
`ifdef USE_POWER_PINS
    inout                                                         vccd1,
    inout                                                         vssd1,
`endif
    input                                                         i_clk,
    input                                                         i_rst_n,
    input                                                         i_weight_shift_en,
    input                                                         i_weight_load,
    input  [P_ARRAY_COLS*P_DATA_WIDTH-1:0]                        i_weight_shift_in,
    input  [P_DATA_WIDTH*P_ARRAY_ROWS-1:0]                        i_feature_vector,
    output [P_ARRAY_COLS*(P_ROW_INDEX_WIDTH+P_DATA_WIDTH*2)-1:0]  o_partial_sum_vector
);
localparam integer LP_MULT_LATENCY     = 1;
localparam integer LP_PE_TOTAL_LATENCY = LP_MULT_LATENCY + 1;
localparam integer LP_PSW              = P_ROW_INDEX_WIDTH + 2*P_DATA_WIDTH;

// NOTE: the row macro is built from gemm_asic_cfg.vh with default parameters;
// keep P_ARRAY_COLS / P_DATA_WIDTH / P_ROW_INDEX_WIDTH equal to those defines.

wire [P_DATA_WIDTH*P_ARRAY_ROWS-1:0] w_feature_skewed;
wire [P_ARRAY_COLS*LP_PSW-1:0]       w_psum_bus   [P_ARRAY_ROWS:0];  // [i] = into row i
wire [P_ARRAY_COLS*P_DATA_WIDTH-1:0] w_weight_bus [P_ARRAY_ROWS:0];  // [i] = out of row i (up)

assign w_psum_bus[0]              = {(P_ARRAY_COLS*LP_PSW){1'b0}};
assign w_weight_bus[P_ARRAY_ROWS] = i_weight_shift_in;

FeatureSkew #(
    .P_DATA_WIDTH (P_DATA_WIDTH),
    .P_ARRAY_ROWS (P_ARRAY_ROWS),
    .P_PE_LATENCY (LP_PE_TOTAL_LATENCY),
    .P_RESET      (`GEMM_DP_RESET)
) u_feature_skew (
    .i_clk            (i_clk),
    .i_rst_n          (i_rst_n),
    .i_feature_vector (i_feature_vector),
    .o_feature_vector (w_feature_skewed)
);

genvar i;
generate
    for (i = 0; i < P_ARRAY_ROWS; i = i + 1) begin : g_pe_row
        // no #( ) here on purpose - see header of PE_row.v
        ProcessingElementRow u_row (
`ifdef USE_POWER_PINS
            .vccd1                (vccd1),
            .vssd1                (vssd1),
`endif
            .i_clk                (i_clk),
            .i_rst_n              (i_rst_n),
            .i_weight_shift_en    (i_weight_shift_en),
            .i_weight_load        (i_weight_load),
            .i_weight_shift_in    (w_weight_bus[i+1]),
            .o_weight_shift_out   (w_weight_bus[i]),
            .i_feature_value      (w_feature_skewed[P_DATA_WIDTH*i +: P_DATA_WIDTH]),
            .i_partial_sum_vector (w_psum_bus[i]),
            .o_partial_sum_vector (w_psum_bus[i+1])
        );
    end
endgenerate

OutputDeskew #(
    .P_PSUM_WIDTH (LP_PSW),
    .P_ARRAY_COLS (P_ARRAY_COLS),
    .P_RESET      (`GEMM_DP_RESET)
) u_output_deskew (
    .i_clk                (i_clk),
    .i_rst_n              (i_rst_n),
    .i_partial_sum_vector (w_psum_bus[P_ARRAY_ROWS]),
    .o_partial_sum_vector (o_partial_sum_vector)
);

endmodule
