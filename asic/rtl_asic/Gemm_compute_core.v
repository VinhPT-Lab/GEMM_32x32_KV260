`timescale 1ns / 1ps
// ---------------------------------------------------------------------------
// GemmComputeCore  (ASIC version)
//
// Only change vs. KV260: the 32-entry x 256-bit weight_buffer shift register
// and the 8192-bit i_weight_matrix bus are gone. The same shift now happens
// inside the PEs (vertical chain), driven by w_weight_shift_en / weight_in.
// w_weight_tile_loaded still fires one cycle after the 32nd word and latches
// the active weights, exactly as before. Counters, valid/last pipes and
// latency constants are untouched.
// Also: LP_AXIS_DATA_WIDTH moved out of the parameter port list (that is an
// SV-only construct; plain Verilog-2005 tools reject it).
// ---------------------------------------------------------------------------
module GemmComputeCore
#(
    parameter P_ARRAY_ROWS = 32,
    parameter P_ARRAY_COLS = 32,
    parameter P_DATA_WIDTH = 8,
    parameter P_ROW_INDEX_WIDTH = 5
)
(
    i_clk,
    i_rst_n,

    o_weight_tile_loaded,

    i_load_weight_phase, 

    i_compute_stream_data,
    i_compute_stream_valid,
    i_compute_stream_last,

    o_partial_data,
    o_partial_valid,
    o_partial_last
);

localparam integer LP_AXIS_DATA_WIDTH = P_ARRAY_ROWS * P_DATA_WIDTH;

input wire                                                      i_clk;
input wire                                                      i_rst_n;

output wire                                                      o_weight_tile_loaded;

input wire                                                      i_load_weight_phase; 

input wire [LP_AXIS_DATA_WIDTH-1:0]                                i_compute_stream_data;
input wire                                                      i_compute_stream_valid;
input wire                                                      i_compute_stream_last;

output wire [P_ARRAY_COLS*(P_ROW_INDEX_WIDTH+P_DATA_WIDTH*2)-1:0]           o_partial_data;
output wire                                                     o_partial_valid;
output wire                                                     o_partial_last;



localparam integer LP_MULT_LATENCY = 1;
localparam integer LP_PE_TOTAL_LATENCY = LP_MULT_LATENCY + 1;
localparam integer LP_RESULT_LATENCY = LP_PE_TOTAL_LATENCY * P_ARRAY_ROWS + P_ARRAY_COLS;
localparam integer LP_RESULT_VALID_LATENCY = LP_RESULT_LATENCY;

reg [P_ARRAY_COLS*(P_ROW_INDEX_WIDTH+P_DATA_WIDTH*2)-1:0]    data_out_reg1;
reg [LP_AXIS_DATA_WIDTH-1:0] feature_in_reg1;
reg r_result_valid_pipe [LP_RESULT_VALID_LATENCY:0];
reg r_result_last_pipe [LP_RESULT_VALID_LATENCY:0];
reg [5:0] weight_buffer_cnt;
reg r_loading_weights;

wire w_weight_tile_loaded;
wire [P_ARRAY_COLS*(P_ROW_INDEX_WIDTH+P_DATA_WIDTH*2)-1:0]  o_data;
wire [P_ARRAY_COLS*(P_ROW_INDEX_WIDTH+P_DATA_WIDTH*2)-1:0] o_partial_sum_vector;
wire [LP_AXIS_DATA_WIDTH-1:0] feature_in;
wire [LP_AXIS_DATA_WIDTH-1:0] weight_in;
wire [P_DATA_WIDTH*P_ARRAY_ROWS-1:0] i_feature_vector;
wire w_weight_shift_en;

genvar i;

// same condition that used to shift weight_buffer[0..N-1]
assign w_weight_shift_en = r_loading_weights & i_compute_stream_valid;

assign o_weight_tile_loaded = w_weight_tile_loaded;
assign o_partial_data = data_out_reg1;
assign weight_in = (r_loading_weights & i_compute_stream_valid) ? i_compute_stream_data : 0;
assign feature_in = ((~r_loading_weights) & i_compute_stream_valid)? i_compute_stream_data : 0;
assign w_weight_tile_loaded = (weight_buffer_cnt==P_ARRAY_ROWS) ? 1:0;
assign i_feature_vector = feature_in_reg1;
assign o_partial_valid = r_result_valid_pipe[LP_RESULT_VALID_LATENCY];
assign o_partial_last = r_result_last_pipe[LP_RESULT_VALID_LATENCY];



always @(posedge i_clk or negedge i_rst_n) begin
    if(~i_rst_n)
        weight_buffer_cnt <= 0;
    else if(weight_buffer_cnt == P_ARRAY_ROWS)
        weight_buffer_cnt<=0;
    else if (r_loading_weights & i_compute_stream_valid)
        weight_buffer_cnt<=weight_buffer_cnt+1;
    else 
        weight_buffer_cnt<=weight_buffer_cnt;
end

always @(posedge i_clk or negedge i_rst_n) begin
    if(~i_rst_n)
        r_loading_weights<=0;
    else 
        case ({i_load_weight_phase,i_compute_stream_last})
            2'b10 :  r_loading_weights <= 1;
            2'b01 :  r_loading_weights <= 0;
            default :  r_loading_weights <= r_loading_weights;
        endcase
end

always @(posedge i_clk)begin
    data_out_reg1 <= o_data;
end

always @(posedge i_clk or negedge i_rst_n) begin
    if(~i_rst_n)
        feature_in_reg1 <= 0;
    else
        feature_in_reg1 <= feature_in;
end

always @(posedge i_clk or negedge i_rst_n) begin
    if(~i_rst_n)
        r_result_valid_pipe[0]<=0;
    else
        r_result_valid_pipe[0]<=i_compute_stream_valid & (~r_loading_weights);
end
generate
    for(i=1;i<=LP_RESULT_VALID_LATENCY;i=i+1)begin
        always @(posedge i_clk or negedge i_rst_n) begin
            if(~i_rst_n)
                r_result_valid_pipe[i]<=0;
            else
                r_result_valid_pipe[i]<=r_result_valid_pipe[i-1];
        end
    end
endgenerate

always @(posedge i_clk or negedge i_rst_n) begin
    if(~i_rst_n)
        r_result_last_pipe[0]<=0;
    else
        r_result_last_pipe[0]<=i_compute_stream_last & (~r_loading_weights);
end

generate
    for(i=1;i<=LP_RESULT_VALID_LATENCY;i=i+1) begin
        always @(posedge i_clk or negedge i_rst_n) begin
            if(~i_rst_n)
                r_result_last_pipe[i]<=0;
            else
                r_result_last_pipe[i]<=r_result_last_pipe[i-1];
        end
    end
endgenerate

ProcessingElementArray#
(
    .P_DATA_WIDTH(P_DATA_WIDTH),
    .P_ARRAY_ROWS(P_ARRAY_ROWS),
    .P_ARRAY_COLS(P_ARRAY_COLS),
    .P_ROW_INDEX_WIDTH(P_ROW_INDEX_WIDTH)
)
u_processing_element_array
(
    .i_clk(i_clk),
    .i_rst_n(i_rst_n),
    .i_weight_shift_en(w_weight_shift_en),
    .i_weight_load(w_weight_tile_loaded),
    .i_weight_shift_in(weight_in),
    .i_feature_vector(i_feature_vector),
    .o_partial_sum_vector(o_partial_sum_vector)
);

assign o_data = o_partial_sum_vector;
endmodule
