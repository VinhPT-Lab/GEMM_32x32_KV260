`timescale 1ns / 1ps
// ---------------------------------------------------------------------------
// InputBuffer  (ASIC version)
// Only change vs. KV260: the two `reg` memories are now sram_1r1w instances
// (behavioural by default, OpenRAM macros with SRAM_USE_SKY130_OPENRAM).
// Read enable is tied high to keep cycle behaviour identical to the original
// (it read every cycle). During IN_DATA the read value is don't-care, so a
// same-address collision there is harmless.
// ---------------------------------------------------------------------------
`define IDLE 2'b00
`define IN_DATA 2'b01
`define CAL 2'b11
// reg [P_ARRAY_SIZE * P_DATA_WIDTH - 1:0] r_feature_buffer_mem [Feature_Width_Block_num * Feature_Length : 0];
// reg [P_ARRAY_SIZE * P_DATA_WIDTH - 1:0] r_weight_buffer_mem [P_ARRAY_SIZE * Weight_Width_Block_num * Feature_Width_Block_num : 0];
module InputBuffer
#(
    parameter integer                               P_ARRAY_SIZE = 32,
    parameter integer                               P_DATA_WIDTH = 8,
    parameter integer                               P_WEIGHT_BUFFER_DEPTH = 2400, 
    parameter integer                               P_FEATURE_BUFFER_DEPTH = 2400,
    parameter integer                               P_ROW_COUNT_WIDTH = 10,
    parameter integer                               P_K_BLOCK_COUNT_WIDTH = 5,
    parameter integer                               P_N_BLOCK_COUNT_WIDTH = 5
)(
    input                                           i_clk,
    input                                           i_rst_n,
    
    input [P_N_BLOCK_COUNT_WIDTH-1:0]             i_cfg_n_block_count, //1 ~ block_num


    input [P_K_BLOCK_COUNT_WIDTH-1:0]             i_cfg_k_block_count, //1 ~ block_num
    input [P_ROW_COUNT_WIDTH-1:0]                      i_cfg_row_count, //1 ~ block_num *P_ARRAY_SIZE

    input                                           i_compute_partial_last,

    input                                           i_feature_valid,
    input                                           i_feature_last,
    output                                          o_feature_ready,
    input [P_ARRAY_SIZE * P_DATA_WIDTH - 1:0]               i_feature_data,

    input                                           i_weight_valid,
    input                                           i_weight_last,
    output                                          o_weight_ready,
    input [P_ARRAY_SIZE * P_DATA_WIDTH - 1:0]               i_weight_data,

    output reg                                      o_buffer_feature_valid,
    output                                          o_buffer_feature_last,
    input                                           i_buffer_feature_ready,
    output     [P_ARRAY_SIZE * P_DATA_WIDTH - 1:0]              o_buffer_feature_data,

    output reg                                      o_buffer_weight_valid,
    output                                          o_buffer_weight_last,
    input                                           i_buffer_weight_ready,
    output     [P_ARRAY_SIZE * P_DATA_WIDTH - 1:0]              o_buffer_weight_data

);

localparam integer LP_F_ADDR_WIDTH = (P_FEATURE_BUFFER_DEPTH <= 1) ? 1 : $clog2(P_FEATURE_BUFFER_DEPTH);
localparam integer LP_W_ADDR_WIDTH = (P_WEIGHT_BUFFER_DEPTH <= 1) ? 1 : $clog2(P_WEIGHT_BUFFER_DEPTH);
localparam integer LP_LOG_A_SIZE = (P_ARRAY_SIZE <= 1) ? 1 : $clog2(P_ARRAY_SIZE);

wire w_start_readout;
wire w_accept_feature_word;
wire w_accept_weight_word;
wire w_accept_buffer_feature_word;
wire w_accept_buffer_weight_word;

 
reg [1:0]                                    state;
reg [LP_W_ADDR_WIDTH-1:0]                    r_weight_words_expected;
reg [LP_F_ADDR_WIDTH-1:0]                    r_feature_words_expected; 

reg [LP_F_ADDR_WIDTH-1:0]                    r_feature_write_count;
reg [LP_F_ADDR_WIDTH-1:0]                    r_feature_write_addr;

reg [LP_W_ADDR_WIDTH-1:0]                    r_weight_write_count;
reg [LP_W_ADDR_WIDTH-1:0]                    r_weight_write_addr;

reg [LP_F_ADDR_WIDTH-1:0]                    r_buffer_feature_count;
reg [P_ROW_COUNT_WIDTH-1:0]                     r_feature_read_row;
reg [P_K_BLOCK_COUNT_WIDTH-1:0]            r_feature_read_k_block;
wire [LP_F_ADDR_WIDTH-1:0]                   w_feature_read_addr;

reg [LP_W_ADDR_WIDTH-1:0]                    r_buffer_weight_count;
reg [LP_W_ADDR_WIDTH-1:0]                    r_weight_read_addr;


assign o_feature_ready = (r_feature_write_count < r_feature_words_expected) & (state == `IN_DATA);
assign o_weight_ready = (r_weight_write_count < r_weight_words_expected) & (state == `IN_DATA);
assign w_feature_read_addr = r_feature_read_row * i_cfg_k_block_count + r_feature_read_k_block;
assign w_start_readout = ((((r_feature_words_expected != 0) && (r_weight_words_expected != 0) &&
                      (r_feature_write_count == r_feature_words_expected) && (r_weight_write_count == r_weight_words_expected))
                    | i_compute_partial_last)
                    & (i_cfg_k_block_count != 0)
                    & (r_feature_read_k_block!=i_cfg_k_block_count));
assign w_accept_feature_word = i_feature_valid & o_feature_ready;
assign w_accept_weight_word = i_weight_valid & o_weight_ready;
assign w_accept_buffer_feature_word = o_buffer_feature_valid & i_buffer_feature_ready;
assign w_accept_buffer_weight_word = o_buffer_weight_valid & i_buffer_weight_ready;
assign o_buffer_feature_last = r_buffer_feature_count == i_cfg_row_count - 1;
assign o_buffer_weight_last = r_buffer_weight_count == i_cfg_n_block_count * P_ARRAY_SIZE - 1; 
always @(posedge i_clk or negedge i_rst_n) begin
    if(~i_rst_n)
        r_feature_words_expected <= 0;
    else
        r_feature_words_expected <= i_cfg_row_count * i_cfg_k_block_count;
end

reg [LP_LOG_A_SIZE + P_K_BLOCK_COUNT_WIDTH-1:0] r_k_elements_per_n_block;
always @(posedge i_clk or negedge i_rst_n) begin
    if(~i_rst_n) begin
        r_k_elements_per_n_block <= 0;
        r_weight_words_expected <= 0;
    end
    else begin
        r_k_elements_per_n_block <= i_cfg_k_block_count * P_ARRAY_SIZE;
        r_weight_words_expected <= i_cfg_n_block_count * r_k_elements_per_n_block;
    end
end

sram_1r1w #(
    .P_WIDTH      (P_ARRAY_SIZE * P_DATA_WIDTH),
    .P_DEPTH      (P_FEATURE_BUFFER_DEPTH),
    .P_ADDR_WIDTH (LP_F_ADDR_WIDTH)
) u_feature_mem (
    .i_clk   (i_clk),
    .i_we    (w_accept_feature_word),
    .i_waddr (r_feature_write_addr),
    .i_wdata (i_feature_data),
    .i_re    (1'b1),
    .i_raddr (w_feature_read_addr),
    .o_rdata (o_buffer_feature_data)
);

sram_1r1w #(
    .P_WIDTH      (P_ARRAY_SIZE * P_DATA_WIDTH),
    .P_DEPTH      (P_WEIGHT_BUFFER_DEPTH),
    .P_ADDR_WIDTH (LP_W_ADDR_WIDTH)
) u_weight_mem (
    .i_clk   (i_clk),
    .i_we    (w_accept_weight_word),
    .i_waddr (r_weight_write_addr),
    .i_wdata (i_weight_data),
    .i_re    (1'b1),
    .i_raddr (r_weight_read_addr),
    .o_rdata (o_buffer_weight_data)
);

always @(posedge i_clk  or negedge i_rst_n) begin
    if(~i_rst_n)
        state <= `IDLE;
    else if (state == `IDLE & (i_feature_valid | i_weight_valid))
        state <= `IN_DATA;
    else if (state == `IN_DATA & w_start_readout)
        state <= `CAL;
    else if (state == `CAL & i_compute_partial_last 
            & ( r_feature_read_k_block == i_cfg_k_block_count))
        state <= `IDLE;
    else
        state <= state;
end

always @(posedge i_clk  or negedge i_rst_n) begin
    if(~i_rst_n)
        r_feature_write_count<=0;
    else if (w_start_readout)
        r_feature_write_count <= 0;
    else if (w_accept_feature_word)
        r_feature_write_count <= r_feature_write_count + 1;
    else
        r_feature_write_count <= r_feature_write_count;
end

always @(posedge i_clk  or negedge i_rst_n) begin
    if(~i_rst_n)
        r_feature_write_addr<=0;
    else if (w_accept_feature_word & i_feature_last)
        r_feature_write_addr <= 0;
    else if (w_accept_feature_word)
        r_feature_write_addr <= r_feature_write_addr + 1;
    else
        r_feature_write_addr <= r_feature_write_addr;
end

always @(posedge i_clk  or negedge i_rst_n) begin
    if(~i_rst_n)
        r_weight_write_count<=0;
    else if (w_start_readout)
        r_weight_write_count <= 0;
    else if (w_accept_weight_word)
        r_weight_write_count <= r_weight_write_count + 1;
    else
        r_weight_write_count <= r_weight_write_count;
end

always @(posedge i_clk  or negedge i_rst_n) begin
    if(~i_rst_n)
        r_weight_write_addr<=0;
    else if (w_accept_weight_word & i_weight_last)
        r_weight_write_addr <= 0;
    else if (w_accept_weight_word)
        r_weight_write_addr <= r_weight_write_addr + 1;
    else
        r_weight_write_addr <= r_weight_write_addr;
end

always @(posedge i_clk  or negedge i_rst_n) begin
    if(~i_rst_n)
        o_buffer_feature_valid <= 0;
    else if(w_start_readout)
        o_buffer_feature_valid <= 1;
    else if (w_accept_buffer_feature_word & o_buffer_feature_last)
        o_buffer_feature_valid <= 0;
    else 
        o_buffer_feature_valid<=o_buffer_feature_valid;
end

always @(posedge i_clk  or negedge i_rst_n) begin
    if(~i_rst_n)
        r_buffer_feature_count<=0;
    else if (r_buffer_feature_count == i_cfg_row_count)
        r_buffer_feature_count<=0;
    else if (w_accept_buffer_feature_word)
        r_buffer_feature_count<=r_buffer_feature_count+1;
    else
        r_buffer_feature_count <= r_buffer_feature_count;
end

always @(posedge i_clk  or negedge i_rst_n) begin
    if(~i_rst_n)
        r_feature_read_row <= 0;
    else if (w_start_readout)
        r_feature_read_row <= 1;
    else if (r_feature_read_row == i_cfg_row_count - 1)
        r_feature_read_row <= 0;
    else if (r_feature_read_row != 0 & w_accept_buffer_feature_word)
        r_feature_read_row <= r_feature_read_row + 1;
    else
        r_feature_read_row <= r_feature_read_row;
end

always @(posedge i_clk  or negedge i_rst_n) begin
    if(~i_rst_n)
       r_feature_read_k_block <= 0;
    else if (i_compute_partial_last & r_feature_read_k_block == i_cfg_k_block_count)
        r_feature_read_k_block <= 0; 
    else if(w_accept_buffer_feature_word & o_buffer_feature_last)
        r_feature_read_k_block <= r_feature_read_k_block + 1;
    else
        r_feature_read_k_block <= r_feature_read_k_block;
end

always @(posedge i_clk  or negedge i_rst_n) begin
    if(~i_rst_n)
        o_buffer_weight_valid <= 0;
    else if(w_start_readout)
        o_buffer_weight_valid <= 1;
    else if (w_accept_buffer_weight_word & o_buffer_weight_last)
        o_buffer_weight_valid <= 0;
    else 
        o_buffer_weight_valid<=o_buffer_weight_valid;
end

always @(posedge i_clk or negedge i_rst_n) begin
    if(~i_rst_n)
        r_buffer_weight_count <= 0;
    else if (r_buffer_weight_count == i_cfg_n_block_count * P_ARRAY_SIZE)
        r_buffer_weight_count <= 0;
    else if (w_accept_buffer_weight_word)
        r_buffer_weight_count<=r_buffer_weight_count+1;
    else
        r_buffer_weight_count<=r_buffer_weight_count;
end

always @(posedge i_clk or negedge i_rst_n ) begin
    if(~i_rst_n)
        r_weight_read_addr <= 0;
    else if (r_weight_read_addr== r_weight_words_expected -1)
        r_weight_read_addr <= 0;
    else if ((w_start_readout
            | w_accept_buffer_weight_word)
            & (~o_buffer_weight_last))
        r_weight_read_addr<=r_weight_read_addr+1;
    else
        r_weight_read_addr<=r_weight_read_addr;
end
endmodule
