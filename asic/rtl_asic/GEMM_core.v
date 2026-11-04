`timescale 1ns / 1ps
`include "gemm_asic_cfg.vh"
// ---------------------------------------------------------------------------
// GemmAccelerator  (ASIC version of rtl/GEMM_core.v) - the hardened "GEMM core"
//
// Only change vs. KV260: the three buffer depths default to the ASIC choice in
// gemm_asic_cfg.vh (weight 1024 / feature 512 / output 512 words = 80 sky130
// OpenRAM macros) instead of 2400. Logic is untouched; a parent (GEMM_top, the
// testbench) can still override the depths.
// Software must keep to the same limits (ggml-cpu.c rtl_shape_ok,
// FPGA_GEMM.cpp IP_BUFFER_DEPTH):  M*k_blocks <= GEMM_F_DEPTH,
// k_blocks*32*n_blocks <= GEMM_W_DEPTH,  M*n_blocks <= GEMM_O_DEPTH.
// ---------------------------------------------------------------------------
module GemmAccelerator
#(
    parameter integer                                       P_ARRAY_SIZE = 32,
    parameter integer                                       P_DATA_WIDTH = 8,
    parameter integer                                       P_SHIFT_WIDTH = 10,
    parameter integer                                       P_WEIGHT_BUFFER_DEPTH = `GEMM_W_DEPTH, 
    parameter integer                                       P_FEATURE_BUFFER_DEPTH = `GEMM_F_DEPTH, 
    parameter integer                                       P_OUTPUT_BUFFER_DEPTH = `GEMM_O_DEPTH,
    parameter integer                                       P_ACCUM_WIDTH = 32,
    parameter integer                                       P_ROW_COUNT_WIDTH = 9,
    parameter integer                                       P_K_BLOCK_COUNT_WIDTH = 5,
    parameter integer                                       P_N_BLOCK_COUNT_WIDTH = 5
)(
    input                                                   i_clk,
    input                                                   i_rst_n,


    input [P_SHIFT_WIDTH-1:0]                                 i_cfg_shift,
    input [P_ROW_COUNT_WIDTH-1:0]                              i_cfg_row_count, 
    input [P_K_BLOCK_COUNT_WIDTH-1:0]                     i_cfg_k_block_count,
    input [P_N_BLOCK_COUNT_WIDTH-1:0]                     i_cfg_n_block_count, 


    input                                                   i_feature_valid,
    input                                                   i_feature_last,
    output                                                  o_feature_ready,
    input [P_ARRAY_SIZE * P_DATA_WIDTH - 1:0]                       i_feature_data,

    input                                                   i_weight_valid,
    input                                                   i_weight_last,
    output                                                  o_weight_ready,
    input [P_ARRAY_SIZE * P_DATA_WIDTH - 1:0]                       i_weight_data,

    output                                                  o_result_valid,
    input                                                   i_result_ready,
    output                                                  o_result_last,
    output [P_ARRAY_SIZE * P_DATA_WIDTH -1:0]                       o_result_data

);
localparam integer LP_LOG2_ARRAY_M = (P_ARRAY_SIZE <= 1) ? 1 : $clog2(P_ARRAY_SIZE);

reg [P_SHIFT_WIDTH-1:0]                                 r_cfg_shift;
reg [P_ROW_COUNT_WIDTH-1:0]                              r_cfg_row_count; 
reg [P_K_BLOCK_COUNT_WIDTH-1:0]                     r_cfg_k_block_count;
reg [P_N_BLOCK_COUNT_WIDTH-1:0]                     r_cfg_n_block_count; 
reg                                                        r_core_active;

wire [P_ARRAY_SIZE*(LP_LOG2_ARRAY_M+P_DATA_WIDTH*2)-1:0]            w_compute_partial_data;
wire                                                        w_compute_partial_valid;
wire                                                        w_compute_partial_last;

wire                                                        w_buffer_feature_valid;
wire                                                        w_buffer_feature_last;
wire                                                        w_buffer_feature_ready;
wire [P_ARRAY_SIZE * P_DATA_WIDTH - 1:0]                            w_buffer_feature_data;

wire                                                        w_buffer_weight_valid;
wire                                                        w_buffer_weight_last;
wire                                                        w_buffer_weight_ready;
wire [P_ARRAY_SIZE * P_DATA_WIDTH - 1:0]                            w_buffer_weight_data;

wire                                                        w_input_accept;
wire                                                        w_final_output_accept;
wire                                                        w_core_active_for_config;

assign w_input_accept = (i_feature_valid & o_feature_ready) | (i_weight_valid & o_weight_ready);
assign w_final_output_accept = o_result_valid & i_result_ready & o_result_last;
assign w_core_active_for_config = r_core_active
                                | w_input_accept
                                | w_buffer_feature_valid
                                | w_buffer_weight_valid
                                | w_compute_partial_valid
                                | o_result_valid;

always @(posedge i_clk or negedge i_rst_n) begin
    if(~i_rst_n)
        r_core_active <= 0;
    else if(w_final_output_accept)
        r_core_active <= 0;
    else if(w_input_accept | w_buffer_feature_valid | w_buffer_weight_valid |
            w_compute_partial_valid | o_result_valid)
        r_core_active <= 1;
    else
        r_core_active <= r_core_active;
end

// Out_buffer's own copy of r_cfg_row_count: same load condition, stored
// inverted so synthesis cannot merge it back into r_cfg_row_count.
// ~r_cfg_row_count_ob_n equals r_cfg_row_count in every cycle (reset: ~'1 = 0).
// r_cfg_row_count fans out to In_buffer, Buffer_feeder and Out_buffer; the
// buffer tree of that fanout made r_cfg_row_count -> result-address multiplier
// -> r_clear_addr the one setup violation left in core_v6 (-0.37 ns).
reg [P_ROW_COUNT_WIDTH-1:0]                              r_cfg_row_count_ob_n;
always @(posedge i_clk or negedge i_rst_n) begin
    if(~i_rst_n)
        r_cfg_row_count_ob_n <= {P_ROW_COUNT_WIDTH{1'b1}};
    else if(~w_core_active_for_config)
        r_cfg_row_count_ob_n <= ~i_cfg_row_count;
    else
        r_cfg_row_count_ob_n <= r_cfg_row_count_ob_n;
end

always @(posedge i_clk or negedge i_rst_n) begin
    if(~i_rst_n) begin
        r_cfg_shift <= 0;
        r_cfg_row_count <= 0;
        r_cfg_k_block_count <= 0;
        r_cfg_n_block_count <= 0;
    end
    else if(~w_core_active_for_config) begin
        r_cfg_shift <= i_cfg_shift;
        r_cfg_row_count <= i_cfg_row_count;
        r_cfg_k_block_count <= i_cfg_k_block_count;
        r_cfg_n_block_count <= i_cfg_n_block_count;
    end
    else begin
        r_cfg_shift <= r_cfg_shift;
        r_cfg_row_count <= r_cfg_row_count;
        r_cfg_k_block_count <= r_cfg_k_block_count;
        r_cfg_n_block_count <= r_cfg_n_block_count;
    end
end

InputBuffer
#(
    .P_ARRAY_SIZE(P_ARRAY_SIZE),
    .P_DATA_WIDTH(P_DATA_WIDTH),
    .P_WEIGHT_BUFFER_DEPTH(P_WEIGHT_BUFFER_DEPTH), 
    .P_FEATURE_BUFFER_DEPTH(P_FEATURE_BUFFER_DEPTH),
    .P_ROW_COUNT_WIDTH(P_ROW_COUNT_WIDTH),
    .P_K_BLOCK_COUNT_WIDTH(P_K_BLOCK_COUNT_WIDTH),
    .P_N_BLOCK_COUNT_WIDTH(P_N_BLOCK_COUNT_WIDTH)
)u_input_buffer(
    .i_clk(i_clk),
    .i_rst_n(i_rst_n),
    
    .i_cfg_n_block_count(r_cfg_n_block_count), //1 ~ block_num
    .i_cfg_k_block_count(r_cfg_k_block_count), //1 ~ block_num
    .i_cfg_row_count(r_cfg_row_count),                   //1 ~ block_num *P_ARRAY_SIZE

    .i_compute_partial_last(w_compute_partial_last),

    .i_feature_valid(i_feature_valid),
    .i_feature_last(i_feature_last),
    .o_feature_ready(o_feature_ready),
    .i_feature_data(i_feature_data),

    .i_weight_valid(i_weight_valid),
    .i_weight_last(i_weight_last),
    .o_weight_ready(o_weight_ready),
    .i_weight_data(i_weight_data),

    .o_buffer_feature_valid(w_buffer_feature_valid),
    .o_buffer_feature_last(w_buffer_feature_last),
    .i_buffer_feature_ready(w_buffer_feature_ready),
    .o_buffer_feature_data(w_buffer_feature_data),

    .o_buffer_weight_valid(w_buffer_weight_valid),
    .o_buffer_weight_last(w_buffer_weight_last),
    .i_buffer_weight_ready(w_buffer_weight_ready),
    .o_buffer_weight_data(w_buffer_weight_data)

);


BufferFeeder
#(
    .P_ARRAY_ROWS(P_ARRAY_SIZE),
    .P_ARRAY_COLS(P_ARRAY_SIZE),
    .P_DATA_WIDTH(P_DATA_WIDTH),
    .P_ROW_INDEX_WIDTH(LP_LOG2_ARRAY_M),
    .P_ROW_COUNT_WIDTH(P_ROW_COUNT_WIDTH),
    .P_N_BLOCK_COUNT_WIDTH(P_N_BLOCK_COUNT_WIDTH)
)u_buffer_feeder(
    .i_clk(i_clk),
    .i_rst_n(i_rst_n),

    .i_cfg_row_count(r_cfg_row_count), //feature length
    .i_cfg_n_block_count(r_cfg_n_block_count),

    .i_buffer_weight_data(w_buffer_weight_data),
    .i_buffer_weight_valid(w_buffer_weight_valid),
    .o_buffer_weight_ready(w_buffer_weight_ready),
    .i_buffer_weight_last(w_buffer_weight_last),

    .i_buffer_feature_data(w_buffer_feature_data),
    .i_buffer_feature_valid(w_buffer_feature_valid),
    .o_buffer_feature_ready(w_buffer_feature_ready),
    .i_buffer_feature_last(w_buffer_feature_last),

    .o_compute_partial_data(w_compute_partial_data),
    .o_compute_partial_valid(w_compute_partial_valid),
    .o_compute_partial_last(w_compute_partial_last)
);


OutputBuffer
#(
    .P_DATA_WIDTH(P_DATA_WIDTH),
    .P_OUTPUT_BUFFER_DEPTH(P_OUTPUT_BUFFER_DEPTH),
    .P_ARRAY_SIZE(P_ARRAY_SIZE),
    .P_SHIFT_WIDTH(P_SHIFT_WIDTH),
    .P_ROW_INDEX_WIDTH(LP_LOG2_ARRAY_M),
    .P_ACCUM_WIDTH(P_ACCUM_WIDTH),
    .P_ROW_COUNT_WIDTH(P_ROW_COUNT_WIDTH),
    .P_K_BLOCK_COUNT_WIDTH(P_K_BLOCK_COUNT_WIDTH),
    .P_N_BLOCK_COUNT_WIDTH(P_N_BLOCK_COUNT_WIDTH)
)u_output_buffer(
    .i_clk(i_clk),
    .i_rst_n(i_rst_n),

    .i_cfg_shift(r_cfg_shift),
    .i_cfg_row_count(~r_cfg_row_count_ob_n), //= r_cfg_row_count, see r_cfg_row_count_ob_n
    .i_cfg_k_block_count(r_cfg_k_block_count), //1 ~ block_num
    .i_cfg_n_block_count(r_cfg_n_block_count), //1 ~ block_num
    
    .i_partial_valid(w_compute_partial_valid),
    .i_partial_last(w_compute_partial_last),
    .i_partial_data(w_compute_partial_data),

    .o_result_valid(o_result_valid),
    .i_result_ready(i_result_ready),
    .o_result_last(o_result_last),
    .o_result_data(o_result_data)
);
endmodule
