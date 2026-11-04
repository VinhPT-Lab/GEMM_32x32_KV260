`timescale 1ns / 1ps
// ---------------------------------------------------------------------------
// OutputBuffer  (ASIC version)
//
// 1) BUG FOR ASIC FIXED: the KV260 version zeroed the accumulation memory
//    with an `initial` block. FPGA BRAM honours that; an ASIC SRAM powers up
//    with random contents and synthesis simply drops `initial`. The first job
//    after power-up would add garbage to its first K block.
//    Fix: during the first K block (r_k_block_done_count == 0) the previous
//    accumulator value is forced to 0 instead of being read from memory.
//    The clear-after-read writes are kept (harmless) so behaviour on the
//    existing testbench is unchanged; they could be removed later to save
//    SRAM write power.
// 2) Memory moved into sram_1r1w. The old "hold read data while
//    r_output_mem_valid & ~i_result_ready" becomes i_re = 0, and the wrapper
//    holds o_rdata.
// ---------------------------------------------------------------------------

module OutputBuffer
#(              
    parameter integer                                        P_DATA_WIDTH = 8,
    parameter integer                                        P_OUTPUT_BUFFER_DEPTH = 2400,
    parameter integer                                        P_ACCUM_WIDTH = 32,
    parameter integer                                        P_ARRAY_SIZE =  32,
    parameter integer                                        P_SHIFT_WIDTH = 20,
    parameter integer                                        P_ROW_INDEX_WIDTH = 5,
    parameter integer                                        P_ROW_COUNT_WIDTH = 10,
    parameter integer                                        P_K_BLOCK_COUNT_WIDTH = 5,
    parameter integer                                        P_N_BLOCK_COUNT_WIDTH = 5
)(
    input                                                    i_clk,
    input                                                    i_rst_n,
        
    input [P_SHIFT_WIDTH - 1:0]                                i_cfg_shift,
    input [P_ROW_COUNT_WIDTH-1:0]                               i_cfg_row_count, //1 ~ block_num *P_ARRAY_SIZE
    input [P_K_BLOCK_COUNT_WIDTH-1:0]                      i_cfg_k_block_count, //1 ~ block_num
    input [P_N_BLOCK_COUNT_WIDTH-1:0]                      i_cfg_n_block_count, //1 ~ block_num
            
    input                                                    i_partial_valid,
    input                                                    i_partial_last,
    input [P_ARRAY_SIZE*(P_ROW_INDEX_WIDTH+P_DATA_WIDTH*2)-1:0]           i_partial_data,

    output reg                                               o_result_valid,
    output                                                   o_result_last,
    input                                                    i_result_ready,
    output reg [P_ARRAY_SIZE * P_DATA_WIDTH -1:0]                    o_result_data
);

localparam integer LP_OUT_ADDR_WIDTH = (P_OUTPUT_BUFFER_DEPTH <= 1) ? 1 : $clog2(P_OUTPUT_BUFFER_DEPTH);


reg  [LP_OUT_ADDR_WIDTH-1:0]                                             r_result_words_expected;
reg  [LP_OUT_ADDR_WIDTH-1:0]                                             r_accum_read_addr;
reg  [LP_OUT_ADDR_WIDTH-1:0]                                             r_accum_write_addr;
wire [P_ARRAY_SIZE*(P_ROW_INDEX_WIDTH+P_DATA_WIDTH*2)-1:0]                            w_partial_sum;
wire [P_ARRAY_SIZE*P_ACCUM_WIDTH-1:0]                                          w_partial_sum_ext;
wire [P_ARRAY_SIZE*P_ACCUM_WIDTH-1:0]                                          w_accum_prev;
wire [P_ARRAY_SIZE*P_ACCUM_WIDTH-1:0]                                          w_accum_next;
reg  [P_K_BLOCK_COUNT_WIDTH-1:0]                                       r_k_block_done_count;

reg                                                                      r_start_result_stream;                   

reg                                                                      r_output_mem_valid;
reg                                                                      r_output_mem_valid_d1;
reg                                                                      r_output_mem_valid_d2;
wire                                                                     w_output_mem_last_d2;
reg  [LP_OUT_ADDR_WIDTH-1:0]                                             r_output_mem_count;
reg  [LP_OUT_ADDR_WIDTH-1:0]                                             r_output_mem_count_d1;


wire [P_ARRAY_SIZE*P_ACCUM_WIDTH-1:0]                                          w_output_mem_data;
reg  [P_ARRAY_SIZE*P_ACCUM_WIDTH-1:0]                                          r_output_mem_data_d1;
wire [P_ARRAY_SIZE * P_DATA_WIDTH -1:0]                                          w_quantized_result_data;
reg  [LP_OUT_ADDR_WIDTH-1:0]                                             r_result_word_count;

reg  [LP_OUT_ADDR_WIDTH-1:0]                                             r_output_mem_write_addr;
reg  [P_ARRAY_SIZE*P_ACCUM_WIDTH-1:0]                                          r_output_mem_write_data;

reg  [P_N_BLOCK_COUNT_WIDTH-1:0]                                       r_result_col_block;
reg  [P_ROW_COUNT_WIDTH-1:0]                                                r_result_row;
wire [LP_OUT_ADDR_WIDTH-1:0]                                             w_result_read_addr;
reg  [LP_OUT_ADDR_WIDTH-1:0]                                             r_clear_addr;

wire [LP_OUT_ADDR_WIDTH-1:0]                                             w_output_mem_read_addr;
wire [P_ARRAY_SIZE*P_ACCUM_WIDTH-1:0]                                          r_output_mem_read_data;  // name kept for diff-ability
wire                                                                     w_output_mem_we;
wire                                                                     w_output_mem_re;


assign w_partial_sum = i_partial_data;
// assign r_start_result_stream = r_k_block_done_count == i_cfg_k_block_count;
assign w_output_mem_last_d2 = r_output_mem_count_d1 == r_result_words_expected;
assign w_result_read_addr = r_result_col_block * i_cfg_row_count + r_result_row;
assign o_result_last = o_result_valid & (r_result_word_count == r_result_words_expected-1);

genvar i;

always @(posedge i_clk or negedge i_rst_n) begin
    if(~i_rst_n)
        r_start_result_stream <= 0;
    else if (r_output_mem_valid)
        r_start_result_stream <= 0;
    else if ((i_cfg_k_block_count != 0) && (r_k_block_done_count == i_cfg_k_block_count))
        r_start_result_stream <= 1;
end

always @(posedge i_clk or negedge i_rst_n) begin
    if(~i_rst_n)
        r_output_mem_valid <= 0;
    else if(r_start_result_stream & i_result_ready)
        r_output_mem_valid <= 1;
    else if(r_output_mem_count == r_result_words_expected - 1 & (r_output_mem_valid&i_result_ready))
        r_output_mem_valid <= 0;
    else 
        r_output_mem_valid <= r_output_mem_valid;
end

always @(posedge i_clk or negedge i_rst_n) begin
    if(~i_rst_n)
        r_output_mem_valid_d1 <= 0;
    else if (r_output_mem_count_d1 ==r_result_words_expected-1 &(r_output_mem_valid_d1&i_result_ready))
        r_output_mem_valid_d1<=0;
    else if (r_output_mem_valid & i_result_ready)
        r_output_mem_valid_d1 <= 1;
    else
        r_output_mem_valid_d1<=r_output_mem_valid_d1;
end

always @(posedge i_clk or negedge i_rst_n) begin
    if(~i_rst_n)
        r_output_mem_valid_d2 <= 0;
    else if(i_result_ready)
        r_output_mem_valid_d2<=r_output_mem_valid_d1;
end

always @(posedge i_clk or negedge i_rst_n) begin
    if(~i_rst_n)
        r_output_mem_count <= 0;
    else if (r_output_mem_count == r_result_words_expected)
        r_output_mem_count <= 0;
    else if (r_output_mem_valid & i_result_ready)
        r_output_mem_count <= r_output_mem_count + 1;
    else
        r_output_mem_count <= r_output_mem_count;
end

always @(posedge i_clk or negedge i_rst_n) begin
    if(~i_rst_n)
        r_result_word_count <= 0;
    else if (r_result_word_count == r_result_words_expected)
        r_result_word_count <= 0;
    else if (o_result_valid & i_result_ready)
        r_result_word_count <= r_result_word_count + 1;
    else
        r_result_word_count <= r_result_word_count;
end

always @(posedge i_clk or negedge i_rst_n) begin
    if(~i_rst_n)
        r_output_mem_count_d1 <= 0;
    else if (r_output_mem_count_d1 == r_result_words_expected)
        r_output_mem_count_d1 <= 0;
    else if (r_output_mem_valid_d1 & i_result_ready)
        r_output_mem_count_d1 <= r_output_mem_count_d1 + 1;
    else
        r_output_mem_count_d1 <= r_output_mem_count_d1;
end

always @(posedge i_clk ) begin
    if(r_output_mem_valid_d1 & i_result_ready)
        r_output_mem_data_d1 <= w_output_mem_data;
    else 
        r_output_mem_data_d1 <= r_output_mem_data_d1;
end


always @(posedge i_clk ) begin
    if(r_output_mem_valid_d2 & i_result_ready)
        o_result_data <= w_quantized_result_data;
    else
        o_result_data <= o_result_data;
end

always @(posedge i_clk or negedge i_rst_n) begin
    if(~i_rst_n)
        o_result_valid <= 0;
    else if(i_result_ready)
        o_result_valid <= r_output_mem_valid_d2;
end

always @(posedge i_clk or negedge i_rst_n) begin
    if(~i_rst_n)
        r_result_col_block <= 0;
    else if (w_output_mem_last_d2)
        r_result_col_block <= 0;
    else if (r_result_col_block == i_cfg_n_block_count-1 & r_result_row == i_cfg_row_count - 1 )
        r_result_col_block <= r_result_col_block;
    else if (r_result_col_block == i_cfg_n_block_count-1 & (r_output_mem_valid & i_result_ready))
        r_result_col_block <= 0;
    else if (r_output_mem_valid & i_result_ready)
        r_result_col_block <= r_result_col_block+1;
end

always @(posedge i_clk or negedge i_rst_n) begin
    if(~i_rst_n)
        r_result_row <= 0;
    else if (w_output_mem_last_d2)
        r_result_row <= 0;
    else if (r_result_row == i_cfg_row_count - 1)
        r_result_row<=r_result_row;
    else if ((r_output_mem_valid & i_result_ready)&
             ((r_result_col_block == i_cfg_n_block_count-1 ) | ( i_cfg_n_block_count == 1 ))
             )
        r_result_row <= r_result_row + 1;
    else
        r_result_row <= r_result_row;
end

always @(*) begin
    if(i_partial_valid)
        r_accum_read_addr = r_accum_write_addr + 1;
    else 
        r_accum_read_addr = r_accum_write_addr;
end

always @(posedge i_clk or negedge i_rst_n) begin
    if(~i_rst_n)
        r_clear_addr <= 0;
    // else if (o_result_last)
    //     r_clear_addr <= 0;
    else if (w_output_mem_last_d2)
        r_clear_addr <= r_result_words_expected - 1;
    // else if (w_result_read_addr == r_result_words_expected - 1)
    else if(r_result_col_block == i_cfg_n_block_count-1 & r_result_row == i_cfg_row_count - 1)
        r_clear_addr <= r_clear_addr;
    else if (r_output_mem_valid & i_result_ready)
        r_clear_addr <= w_result_read_addr;
end

always @(*) begin
    case (i_partial_valid)
        1'b1: r_output_mem_write_addr = r_accum_write_addr;
        1'b0: r_output_mem_write_addr = r_clear_addr; 
        default: r_output_mem_write_addr = 0;
    endcase
end

// write port: accumulate, or clear-after-read during result streaming
assign w_output_mem_we = i_partial_valid | r_output_mem_valid_d1 | (o_result_valid & i_result_ready);

always @(*) begin
    if(i_partial_valid)
        r_output_mem_write_data = w_accum_next;
    else
        r_output_mem_write_data = 0;
end

assign w_output_mem_read_addr = (r_output_mem_valid_d2 | r_output_mem_valid)? w_result_read_addr : r_accum_read_addr;

// read port: hold (i_re = 0) under back-pressure, exactly like before
assign w_output_mem_re = ~(r_output_mem_valid & ~i_result_ready);

sram_1r1w #(
    .P_WIDTH      (P_ARRAY_SIZE*P_ACCUM_WIDTH),
    .P_DEPTH      (P_OUTPUT_BUFFER_DEPTH),
    .P_ADDR_WIDTH (LP_OUT_ADDR_WIDTH)
) u_accum_mem (
    .i_clk   (i_clk),
    .i_we    (w_output_mem_we),
    .i_waddr (r_output_mem_write_addr),
    .i_wdata (r_output_mem_write_data),
    .i_re    (w_output_mem_re),
    .i_raddr (w_output_mem_read_addr),
    .o_rdata (r_output_mem_read_data)
);
                            
// first K block starts from zero - no dependence on memory power-up state
assign w_accum_prev = (r_k_block_done_count == 0) ? {(P_ARRAY_SIZE*P_ACCUM_WIDTH){1'b0}} : r_output_mem_read_data;
assign w_output_mem_data = r_output_mem_read_data;

always @(posedge i_clk or negedge i_rst_n) begin
    if(~i_rst_n)
        r_result_words_expected <= 0;
    else
        r_result_words_expected <= i_cfg_row_count * i_cfg_n_block_count;
end

always @(posedge i_clk or negedge i_rst_n) begin
    if(~i_rst_n)
        r_accum_write_addr <= 0;
    else if (i_partial_last)
        r_accum_write_addr <= 0;
    else if(i_partial_valid)
        r_accum_write_addr <= r_accum_write_addr + 1;
    else
        r_accum_write_addr <= r_accum_write_addr;
end

always @(posedge i_clk or negedge i_rst_n) begin
    if(~i_rst_n)
        r_k_block_done_count <= 0;
    else if ((i_cfg_k_block_count != 0) && (r_k_block_done_count == i_cfg_k_block_count))
        r_k_block_done_count <= 0;
    else if (i_partial_last)
        r_k_block_done_count <= r_k_block_done_count + 1;
    else 
        r_k_block_done_count <= r_k_block_done_count;
end


SignedAdder 
#(
    .P_DATA_WIDTH(P_ACCUM_WIDTH),
    .P_ARRAY_SIZE(P_ARRAY_SIZE)
)u_signed_adder 
(
    .i_addend_a(w_partial_sum_ext),
    .i_addend_b(w_accum_prev),
    .o_sum_sat(w_accum_next)
);

generate
    for(i=0;i<P_ARRAY_SIZE;i=i+1)begin
        assign w_partial_sum_ext[i*P_ACCUM_WIDTH +: P_ACCUM_WIDTH] = $signed(w_partial_sum[i*(P_ROW_INDEX_WIDTH+P_DATA_WIDTH*2) +: (P_ROW_INDEX_WIDTH+P_DATA_WIDTH*2)]);
    end
endgenerate

generate
    for(i=0;i<P_ARRAY_SIZE;i=i+1)begin:g_quantize_lane
        RightShifter 
        #(
            .P_INPUT_WIDTH(P_ACCUM_WIDTH),
            .P_OUTPUT_WIDTH(P_DATA_WIDTH),
            .P_SHIFT_WIDTH(P_SHIFT_WIDTH)
        )u_right_shifter(
            .i_shift_amount(i_cfg_shift),
            .i_data(r_output_mem_data_d1[i*P_ACCUM_WIDTH +: P_ACCUM_WIDTH]),
            .o_data(w_quantized_result_data[i*P_DATA_WIDTH+:P_DATA_WIDTH])
        );
    end
endgenerate
endmodule
