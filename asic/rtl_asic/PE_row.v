`timescale 1ns / 1ps
`include "gemm_asic_cfg.vh"
// ---------------------------------------------------------------------------
// ProcessingElementRow  (ASIC version)  -  this is the module hardened as a
// macro and instantiated GEMM_N times.
//
// Boundary (all short, all registered on at least one side):
//   top edge    : i_partial_sum_vector  (psum flows DOWN)
//                 o_weight_shift_out    (weights flow UP)
//   bottom edge : o_partial_sum_vector
//                 i_weight_shift_in
//   left edge   : i_feature_value, i_clk, i_rst_n, i_weight_shift_en,
//                 i_weight_load
// Pin j of the top edge sits exactly above pin j of the bottom edge
// (pin_order.cfg from openlane/gen_openlane_files.py) so stacked rows connect with straight wires.
//
// Do NOT override the parameters when instantiating this module; change
// gemm_asic_cfg.vh instead.
// ---------------------------------------------------------------------------
module ProcessingElementRow
#(
    parameter P_ARRAY_COLS      = `GEMM_N,
    parameter P_DATA_WIDTH      = `GEMM_DW,
    parameter P_ROW_INDEX_WIDTH = `GEMM_RIW,
    parameter P_DATAPATH_RESET  = `GEMM_DP_RESET
)
(
`ifdef USE_POWER_PINS
    inout                                                           vccd1,   // OpenLane macro power pins
    inout                                                           vssd1,
`endif
    input                                                           i_clk,
    input                                                           i_rst_n,
    input                                                           i_weight_shift_en,
    input                                                           i_weight_load,
    input  [P_ARRAY_COLS*P_DATA_WIDTH-1:0]                          i_weight_shift_in,
    output [P_ARRAY_COLS*P_DATA_WIDTH-1:0]                          o_weight_shift_out,
    input  [P_DATA_WIDTH-1:0]                                       i_feature_value,
    input  [P_ARRAY_COLS*(P_ROW_INDEX_WIDTH+P_DATA_WIDTH*2)-1:0]    i_partial_sum_vector,
    output [P_ARRAY_COLS*(P_ROW_INDEX_WIDTH+P_DATA_WIDTH*2)-1:0]    o_partial_sum_vector
);
localparam integer LP_PSW = P_ROW_INDEX_WIDTH + 2*P_DATA_WIDTH;

// feature travels left -> right, one register per PE
wire [P_DATA_WIDTH-1:0] w_feature_lane [P_ARRAY_COLS:0];
assign w_feature_lane[0] = i_feature_value;

genvar i;
generate
    for (i = 0; i < P_ARRAY_COLS; i = i + 1) begin : g_pe_column
        ProcessingElement #(
            .P_DATA_WIDTH      (P_DATA_WIDTH),
            .P_ROW_INDEX_WIDTH (P_ROW_INDEX_WIDTH),
            .P_DATAPATH_RESET  (P_DATAPATH_RESET)
        ) u_processing_element (
            .i_clk              (i_clk),
            .i_rst_n            (i_rst_n),
            .i_weight_shift_en  (i_weight_shift_en),
            .i_weight_load      (i_weight_load),
            .i_weight_shift_in  (i_weight_shift_in [P_DATA_WIDTH*i +: P_DATA_WIDTH]),
            .o_weight_shift_out (o_weight_shift_out[P_DATA_WIDTH*i +: P_DATA_WIDTH]),
            .i_feature_value    (w_feature_lane[i]),
            .i_partial_sum      (i_partial_sum_vector[LP_PSW*i +: LP_PSW]),
            .o_feature_value    (w_feature_lane[i+1]),
            .o_partial_sum      (o_partial_sum_vector[LP_PSW*i +: LP_PSW])
        );
    end
endgenerate

endmodule
