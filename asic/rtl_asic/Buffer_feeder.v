`timescale 1ns / 1ps
// ---------------------------------------------------------------------------
// BufferFeeder  (ASIC version)
// Only change vs. KV260: weight_buffer / feature_buffer are sram_1r1w
// instances. Read enable tied high = same "read every cycle" behaviour.
// Sizes: weight = 2^P_N_BLOCK_COUNT_WIDTH * P_ARRAY_ROWS words,
//        feature = 2^P_ROW_COUNT_WIDTH words (x 256 bit each).
// ---------------------------------------------------------------------------
`define IDLE 2'b00
`define SET_WEIGHT 2'b01
`define SET_FEATURE 2'b11

module BufferFeeder#
(
    parameter integer                                  P_ARRAY_ROWS = 32,
    parameter integer                                  P_ARRAY_COLS = 32,
    parameter integer                                  P_DATA_WIDTH = 8,
    parameter integer                                  P_ROW_INDEX_WIDTH = 5,
    parameter integer                                  P_ROW_COUNT_WIDTH = 10,
    parameter integer                                  P_N_BLOCK_COUNT_WIDTH = 5 
)(
    input                                                   i_clk,
    input                                                   i_rst_n,


    input [P_ROW_COUNT_WIDTH-1:0]                              i_cfg_row_count, 
    input [P_N_BLOCK_COUNT_WIDTH-1:0]                     i_cfg_n_block_count, 


    input [P_ARRAY_ROWS * P_DATA_WIDTH - 1:0]                      i_buffer_weight_data,
    input                                                   i_buffer_weight_valid,
    output                                                  o_buffer_weight_ready,
    input                                                   i_buffer_weight_last,

    input [P_ARRAY_ROWS * P_DATA_WIDTH - 1:0]                      i_buffer_feature_data,
    input                                                   i_buffer_feature_valid,
    output                                                  o_buffer_feature_ready,
    input                                                   i_buffer_feature_last,

    output [P_ARRAY_COLS*(P_ROW_INDEX_WIDTH+P_DATA_WIDTH*2)-1:0]        o_compute_partial_data,
    output                                                  o_compute_partial_valid,
    output                                                  o_compute_partial_last
);
localparam integer LP_FEATURE_BUFFER_DEPTH = (1 << P_ROW_COUNT_WIDTH);
localparam integer LP_WEIGHT_ADDR_WIDTH = P_N_BLOCK_COUNT_WIDTH + P_ROW_INDEX_WIDTH;
localparam integer LP_WEIGHT_BUFFER_DEPTH = (1 << P_N_BLOCK_COUNT_WIDTH) * P_ARRAY_ROWS;


reg [1:0]                                                   state;


reg                                                         start;
wire                                                        start_ahead1;
reg                                                         r_weight_loaded_d1;
reg                                                         w_end;
reg                                                         weight_flag_up;

reg [LP_WEIGHT_ADDR_WIDTH-1:0]                              r_total_weight_words;
reg [P_ROW_COUNT_WIDTH-1:0]                                    r_cfg_row_count_latched;

reg [LP_WEIGHT_ADDR_WIDTH-1:0]                              weight_buffer_cnt;
reg [LP_WEIGHT_ADDR_WIDTH-1:0]                              weight_buffer_in_addr;

reg [P_ROW_COUNT_WIDTH-1:0]                                    feature_buffer_cnt;
reg [P_ROW_COUNT_WIDTH-1:0]                                    feature_buffer_in_addr;

wire                                                        both_full;
reg                                                         both_full_delay1;

reg [P_ARRAY_ROWS * P_DATA_WIDTH - 1:0]                            r_compute_input_data;
reg                                                         r_compute_input_valid;
reg                                                         r_compute_input_last;

reg                                                         input_weight_valid;
wire                                                        input_weight_last;
wire [P_ARRAY_ROWS * P_DATA_WIDTH - 1:0]                           input_weight_data;
wire [LP_WEIGHT_ADDR_WIDTH-1:0]                             input_weight_addr;
reg [P_N_BLOCK_COUNT_WIDTH-1:0]                           input_weight_col;
reg [P_ROW_INDEX_WIDTH-1:0]                                      input_weight_row;
reg [LP_WEIGHT_ADDR_WIDTH-1:0]                              weight_cnt;                                

reg                                                         input_feature_valid;
wire                                                        input_feature_last;
wire [P_ARRAY_ROWS * P_DATA_WIDTH - 1:0]                           input_feature_data;
reg [P_ROW_COUNT_WIDTH-1:0]                                    input_feature_addr;
reg [P_ROW_COUNT_WIDTH-1:0]                                    feature_cnt;

wire                                                        w_weight_tile_loaded;
wire                                                        total_last;
wire                                                        i_load_weight_phase;
wire                                                        w_accept_input_weight;
wire                                                        w_accept_input_feature;

wire [P_ARRAY_COLS*(P_ROW_INDEX_WIDTH+P_DATA_WIDTH*2)-1:0]              output_feature_data;
wire                                                        output_feature_valid;
wire                                                        output_feature_last;


assign both_full = (weight_buffer_cnt == r_total_weight_words) & (feature_buffer_cnt == r_cfg_row_count_latched);
assign o_compute_partial_valid = output_feature_valid;
assign o_compute_partial_data = output_feature_data;
assign o_compute_partial_last = total_last;
assign total_last = output_feature_last & w_end;
assign o_buffer_weight_ready = (r_total_weight_words != 0) & (weight_buffer_cnt < r_total_weight_words);
assign o_buffer_feature_ready = (r_cfg_row_count_latched != 0) & (feature_buffer_cnt < r_cfg_row_count_latched);
// assign i_load_weight_phase = start | weight_flag_up;
assign i_load_weight_phase = start | weight_flag_up & (state != 0);
assign input_weight_last = weight_cnt == P_ARRAY_ROWS - 1;
assign input_feature_last = feature_cnt == r_cfg_row_count_latched - 1;
assign input_weight_addr = input_weight_row * i_cfg_n_block_count + input_weight_col;
assign start_ahead1 = (r_total_weight_words != 0) & (r_cfg_row_count_latched != 0) & both_full & (~both_full_delay1);
assign w_accept_input_weight = i_buffer_weight_valid & o_buffer_weight_ready;
assign w_accept_input_feature = i_buffer_feature_valid & o_buffer_feature_ready;


always @(*) begin
    case (state)
        `IDLE : begin
            r_compute_input_valid = 0;
            r_compute_input_last = 0;
            r_compute_input_data = 0;
        end 
        `SET_WEIGHT : begin
            r_compute_input_valid = input_weight_valid;
            r_compute_input_last = input_weight_last;
            r_compute_input_data = input_weight_data;
        end
        `SET_FEATURE: begin
            r_compute_input_valid = input_feature_valid;
            r_compute_input_last = input_feature_last;
            r_compute_input_data = input_feature_data;
        end
        default: begin
            r_compute_input_valid = 0;
            r_compute_input_last = 0;
            r_compute_input_data = 0;
        end
    endcase
end

always @(posedge i_clk or negedge i_rst_n) begin
    if(~i_rst_n)
        both_full_delay1 <= 0;
    else
        both_full_delay1 <= both_full;
end

always @(posedge i_clk or negedge i_rst_n) begin
    if(~i_rst_n)
        start <= 0;
    else
        start <= start_ahead1;
end

always @(posedge i_clk or negedge i_rst_n) begin
    if(~i_rst_n)
        r_weight_loaded_d1 <= 0;
    else
        r_weight_loaded_d1 <= w_weight_tile_loaded;
end

always @(posedge i_clk or negedge i_rst_n) begin
    if(~i_rst_n)
        r_total_weight_words <= 0;
    else
        r_total_weight_words <= i_cfg_n_block_count * P_ARRAY_ROWS;
end

always @(posedge i_clk or negedge i_rst_n) begin
    if(~i_rst_n)
        r_cfg_row_count_latched <= 0;
    else
        r_cfg_row_count_latched <= i_cfg_row_count;
end

always @(posedge i_clk or negedge i_rst_n) begin
    if(~i_rst_n)
        weight_buffer_cnt <= 0;
    else if (w_accept_input_weight)
        weight_buffer_cnt <= weight_buffer_cnt + 1;
    else if (total_last)
        weight_buffer_cnt <= 0;
    else
        weight_buffer_cnt <= weight_buffer_cnt;
end

always @(posedge i_clk or negedge i_rst_n) begin
    if(~i_rst_n)
        feature_buffer_cnt <= 0;
    else if (w_accept_input_feature)
        feature_buffer_cnt <= feature_buffer_cnt + 1;
    else if (total_last)
        feature_buffer_cnt <= 0;
    else
        feature_buffer_cnt <= feature_buffer_cnt;
end

always @(posedge i_clk or negedge i_rst_n) begin
    if(~i_rst_n)
        w_end <= 1;
    else if(start)
        w_end <= 0;
    else if (input_weight_addr == r_total_weight_words -1)
        w_end <= 1;
    else 
        w_end <= w_end;
end

always @(posedge i_clk or negedge i_rst_n) begin
    if(~i_rst_n)
        weight_buffer_in_addr <= 0;
    else if (w_accept_input_weight & i_buffer_weight_last)
        weight_buffer_in_addr <= 0;
    else if (w_accept_input_weight)
        weight_buffer_in_addr <= weight_buffer_in_addr + 1;
    else 
        weight_buffer_in_addr <= weight_buffer_in_addr;
end

sram_1r1w #(
    .P_WIDTH      (P_ARRAY_ROWS * P_DATA_WIDTH),
    .P_DEPTH      (LP_WEIGHT_BUFFER_DEPTH),
    .P_ADDR_WIDTH (LP_WEIGHT_ADDR_WIDTH)
) u_weight_tile_mem (
    .i_clk   (i_clk),
    .i_we    (w_accept_input_weight),
    .i_waddr (weight_buffer_in_addr),
    .i_wdata (i_buffer_weight_data),
    .i_re    (1'b1),
    .i_raddr (input_weight_addr),
    .o_rdata (input_weight_data)
);

always @(posedge i_clk or negedge i_rst_n) begin
    if(~i_rst_n)
        feature_buffer_in_addr <= 0;
    else if (w_accept_input_feature & i_buffer_feature_last)
        feature_buffer_in_addr <= 0;
    else if (w_accept_input_feature)
        feature_buffer_in_addr <= feature_buffer_in_addr + 1;
    else 
        feature_buffer_in_addr <= feature_buffer_in_addr;
end

sram_1r1w #(
    .P_WIDTH      (P_ARRAY_ROWS * P_DATA_WIDTH),
    .P_DEPTH      (LP_FEATURE_BUFFER_DEPTH),
    .P_ADDR_WIDTH (P_ROW_COUNT_WIDTH)
) u_feature_tile_mem (
    .i_clk   (i_clk),
    .i_we    (w_accept_input_feature),
    .i_waddr (feature_buffer_in_addr),
    .i_wdata (i_buffer_feature_data),
    .i_re    (1'b1),
    .i_raddr (input_feature_addr),
    .o_rdata (input_feature_data)
);

always @(posedge i_clk or negedge i_rst_n) begin
    if(~i_rst_n)
        state <= `IDLE;
    else if (state == `IDLE) begin //only start can wake up state
        if (start)
            state <= `SET_WEIGHT;
        else
            state <= state;
    end
    else begin
        case ({weight_flag_up, r_weight_loaded_d1,total_last})
            3'b100: state <= `SET_WEIGHT;
            3'b010: state <= `SET_FEATURE;
            3'b001: state <= `IDLE;
            default: state <= state;
        endcase
    end
end

always @(posedge i_clk or negedge i_rst_n) begin
    if (~i_rst_n)
        weight_flag_up <= 0;
    else if(weight_flag_up)
        weight_flag_up <= 0;
    else if (output_feature_last)
        weight_flag_up <= 1;
end

always @(posedge i_clk or negedge i_rst_n) begin
    if(~i_rst_n)
        input_weight_valid <= 0;
    else if(i_load_weight_phase)
        input_weight_valid <= 1;
    else if(input_weight_last)
        input_weight_valid <= 0;
    else
        input_weight_valid <= input_weight_valid;
end


always @(posedge i_clk or negedge i_rst_n) begin
    if(~i_rst_n)
        weight_cnt <= 0;
    else if (weight_cnt == P_ARRAY_ROWS)
        weight_cnt <= 0;
    else if (state == `SET_WEIGHT & input_weight_valid)
        weight_cnt <= weight_cnt + 1;
    else
        weight_cnt <= weight_cnt;
end

always @(posedge i_clk or negedge i_rst_n) begin
    if(~i_rst_n)
        input_feature_valid <= 0;
    else if (r_weight_loaded_d1)
        input_feature_valid <= 1;
    else if (input_feature_last)
        input_feature_valid <= 0;
    else 
        input_feature_valid <= input_feature_valid;
end


always @(posedge i_clk or negedge i_rst_n) begin
    if(~i_rst_n)
        input_feature_addr <= 0;
    else if (input_feature_addr == r_cfg_row_count_latched - 1)
        input_feature_addr <= 0;
    else if (r_weight_loaded_d1)
        input_feature_addr <= 1;
    else if (state == `SET_FEATURE & input_feature_valid & input_feature_addr!=0)
        input_feature_addr <= input_feature_addr + 1;
    else
        input_feature_addr <= input_feature_addr;
end

always @(posedge i_clk or negedge i_rst_n) begin
    if(~i_rst_n)
        feature_cnt <= 0;
    else if(feature_cnt == r_cfg_row_count_latched)
        feature_cnt <= 0;
    else if(state == `SET_FEATURE & input_feature_valid)
        feature_cnt <= feature_cnt + 1;
    else 
        feature_cnt <= feature_cnt;
end

always @(posedge i_clk or negedge i_rst_n) begin
    if(~i_rst_n)
        input_weight_col <= 0;
    else if(input_weight_col == i_cfg_n_block_count)
        input_weight_col <= 0;
    else if(input_weight_last)
        input_weight_col <= input_weight_col + 1;
    else
        input_weight_col <= input_weight_col;
end

always @(posedge i_clk or negedge i_rst_n) begin
    if(~i_rst_n)
        input_weight_row <= 0;
    else if (input_weight_row == P_ARRAY_ROWS - 1)
        input_weight_row <= 0;
    else if (i_load_weight_phase)
        input_weight_row <= 1;
    else if (input_weight_row != 0)
        input_weight_row <= input_weight_row + 1;
end

GemmComputeCore
#(
    .P_ARRAY_ROWS(P_ARRAY_ROWS), //Array 行数
    .P_ARRAY_COLS(P_ARRAY_COLS), //Array 列数
    .P_DATA_WIDTH(P_DATA_WIDTH), //数据宽度
    .P_ROW_INDEX_WIDTH(P_ROW_INDEX_WIDTH)
) u_compute_core
(
    .i_clk(i_clk),
    .i_rst_n(i_rst_n),

    .o_weight_tile_loaded(w_weight_tile_loaded),

    .i_load_weight_phase(i_load_weight_phase), 

    .i_compute_stream_data(r_compute_input_data),
    .i_compute_stream_valid(r_compute_input_valid),
    .i_compute_stream_last(r_compute_input_last),

    .o_partial_data(output_feature_data),
    .o_partial_valid(output_feature_valid),
    .o_partial_last(output_feature_last)
);
    
endmodule
