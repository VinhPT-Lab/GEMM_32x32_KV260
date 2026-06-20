`timescale 1ns / 1ps

module GEMM_top
#(
    parameter integer C_S_AXI_DATA_WIDTH = 32,
    parameter integer C_S_AXI_ADDR_WIDTH = 4,
    parameter integer A_size = 32,
    parameter integer data_width = 8,
    parameter integer shift_width = 10,
    parameter integer Weight_Block_num = 2400,
    parameter integer IN_Feature_Block_num = 2400,
    parameter integer OUT_Feature_Block_num = 2400,
    parameter integer OUT_MEM_WIDTH = 32,
    parameter integer F_length_width = 9,
    parameter integer F_width_block_num_width = 5,
    parameter integer W_width_block_num_width = 5
)
(
    //----------------------------------
    // AXI-Lite Control
    //----------------------------------
    input wire  S_AXI_ACLK,
    input wire  S_AXI_ARESETN,

    input wire [C_S_AXI_ADDR_WIDTH-1:0] S_AXI_AWADDR,
    input wire [2:0] S_AXI_AWPROT,
    input wire S_AXI_AWVALID,
    output wire S_AXI_AWREADY,

    input wire [C_S_AXI_DATA_WIDTH-1:0] S_AXI_WDATA,
    input wire [(C_S_AXI_DATA_WIDTH/8)-1:0] S_AXI_WSTRB,
    input wire S_AXI_WVALID,
    output wire S_AXI_WREADY,

    output wire [1:0] S_AXI_BRESP,
    output wire S_AXI_BVALID,
    input wire S_AXI_BREADY,

    input wire [C_S_AXI_ADDR_WIDTH-1:0] S_AXI_ARADDR,
    input wire [2:0] S_AXI_ARPROT,
    input wire S_AXI_ARVALID,
    output wire S_AXI_ARREADY,

    output wire [C_S_AXI_DATA_WIDTH-1:0] S_AXI_RDATA,
    output wire [1:0] S_AXI_RRESP,
    output wire S_AXI_RVALID,
    input wire S_AXI_RREADY,

    //----------------------------------
    // Feature AXIS Slave
    //----------------------------------
    output wire         feature_axis_tready,
    input  wire [A_size*data_width-1:0] feature_axis_tdata,
    input  wire [(A_size*data_width/8)-1:0]  feature_axis_tstrb,
    input  wire         feature_axis_tlast,
    input  wire         feature_axis_tvalid,

    //----------------------------------
    // Weight AXIS Slave
    //----------------------------------
    output wire         weight_axis_tready,
    input  wire [A_size*data_width-1:0] weight_axis_tdata,
    input  wire [(A_size*data_width/8)-1:0]  weight_axis_tstrb,
    input  wire         weight_axis_tlast,
    input  wire         weight_axis_tvalid,

    //----------------------------------
    // Result AXIS Master
    //----------------------------------
    output wire         result_axis_tvalid,
    output wire [A_size*data_width-1:0] result_axis_tdata,
    output wire [(A_size*data_width/8)-1:0]  result_axis_tstrb,
    output wire         result_axis_tlast,
    input  wire         result_axis_tready
);


//=====================================================
// AXI-Lite Control Registers
//=====================================================

wire [shift_width-1:0] shift;
wire [F_length_width-1:0] F_length;
wire [F_width_block_num_width-1:0] F_width;
wire [W_width_block_num_width-1:0] W_width;

Control_register_file #(
    .C_S_AXI_DATA_WIDTH(C_S_AXI_DATA_WIDTH),
    .C_S_AXI_ADDR_WIDTH(C_S_AXI_ADDR_WIDTH)
)
u_control_register_file
(
    .shift_out(shift),
    .F_length_out(F_length),
    .F_width_out(F_width),
    .W_width_out(W_width),

    .S_AXI_ACLK(S_AXI_ACLK),
    .S_AXI_ARESETN(S_AXI_ARESETN),

    .S_AXI_AWADDR(S_AXI_AWADDR),
    .S_AXI_AWPROT(S_AXI_AWPROT),
    .S_AXI_AWVALID(S_AXI_AWVALID),
    .S_AXI_AWREADY(S_AXI_AWREADY),

    .S_AXI_WDATA(S_AXI_WDATA),
    .S_AXI_WSTRB(S_AXI_WSTRB),
    .S_AXI_WVALID(S_AXI_WVALID),
    .S_AXI_WREADY(S_AXI_WREADY),

    .S_AXI_BRESP(S_AXI_BRESP),
    .S_AXI_BVALID(S_AXI_BVALID),
    .S_AXI_BREADY(S_AXI_BREADY),

    .S_AXI_ARADDR(S_AXI_ARADDR),
    .S_AXI_ARPROT(S_AXI_ARPROT),
    .S_AXI_ARVALID(S_AXI_ARVALID),
    .S_AXI_ARREADY(S_AXI_ARREADY),

    .S_AXI_RDATA(S_AXI_RDATA),
    .S_AXI_RRESP(S_AXI_RRESP),
    .S_AXI_RVALID(S_AXI_RVALID),
    .S_AXI_RREADY(S_AXI_RREADY)
);


//=====================================================
// AXIS Signals
//=====================================================

wire [A_size*data_width-1:0] feature_data;
wire         feature_valid;
wire         feature_last;
wire         feature_ready;

wire [A_size*data_width-1:0] weight_data;
wire         weight_valid;
wire         weight_last;
wire         weight_ready;

wire [A_size*data_width-1:0] result_data;
wire         result_valid;
wire         result_last;
wire         result_ready;


//=====================================================
// Feature AXIS
//=====================================================

Feature_stream_slave #(
    .C_feature_axis_TDATA_WIDTH(A_size*data_width)
)
u_feature_stream_slave
(
    .feature_data(feature_data),
    .feature_valid(feature_valid),
    .feature_last(feature_last),
    .feature_ready(feature_ready),

    .feature_axis_aclk(S_AXI_ACLK),
    .feature_axis_aresetn(S_AXI_ARESETN),
    .feature_axis_tready(feature_axis_tready),
    .feature_axis_tdata(feature_axis_tdata),
    .feature_axis_tstrb(feature_axis_tstrb),
    .feature_axis_tlast(feature_axis_tlast),
    .feature_axis_tvalid(feature_axis_tvalid)
);


//=====================================================
// Weight AXIS
//=====================================================

Weight_stream_slave #(
    .C_weight_axis_TDATA_WIDTH(A_size*data_width)
)
u_weight_stream_slave
(
    .weight_data(weight_data),
    .weight_valid(weight_valid),
    .weight_last(weight_last),
    .weight_ready(weight_ready),

    .weight_axis_aclk(S_AXI_ACLK),
    .weight_axis_aresetn(S_AXI_ARESETN),
    .weight_axis_tready(weight_axis_tready),
    .weight_axis_tdata(weight_axis_tdata),
    .weight_axis_tstrb(weight_axis_tstrb),
    .weight_axis_tlast(weight_axis_tlast),
    .weight_axis_tvalid(weight_axis_tvalid)
);


//=====================================================
// GEMM Core
//=====================================================

GEMM_core #(
    .A_size(A_size),
    .data_width(data_width),
    .shift_width(shift_width),
    .Weight_Block_num(Weight_Block_num),
    .IN_Feature_Block_num(IN_Feature_Block_num),
    .OUT_Feature_Block_num(OUT_Feature_Block_num),
    .OUT_MEM_WIDTH(OUT_MEM_WIDTH),
    .F_length_width(F_length_width),
    .F_width_block_num_width(F_width_block_num_width),
    .W_width_block_num_width(W_width_block_num_width)
)
u_gemm_core
(
    .clk(S_AXI_ACLK),
    .rst_n(S_AXI_ARESETN),

    .shift_in(shift),
    .F_length_in(F_length),
    .F_width_block_num_in(F_width),
    .W_width_block_num_in(W_width),

    .in_F_valid(feature_valid),
    .in_F_last(feature_last),
    .in_F_ready(feature_ready),
    .in_F_data(feature_data),

    .in_W_valid(weight_valid),
    .in_W_last(weight_last),
    .in_W_ready(weight_ready),
    .in_W_data(weight_data),

    .out_data_valid(result_valid),
    .out_data_ready(result_ready),
    .out_data_last(result_last),
    .out_data(result_data)
);


//=====================================================
// Result AXIS
//=====================================================

Result_stream_master #(
    .C_result_axis_TDATA_WIDTH(A_size*data_width)
)
u_result_stream_master
(
    .result_data(result_data),
    .result_valid(result_valid),
    .result_last(result_last),
    .result_ready(result_ready),

    .result_axis_aclk(S_AXI_ACLK),
    .result_axis_aresetn(S_AXI_ARESETN),

    .result_axis_tvalid(result_axis_tvalid),
    .result_axis_tdata(result_axis_tdata),
    .result_axis_tstrb(result_axis_tstrb),
    .result_axis_tlast(result_axis_tlast),
    .result_axis_tready(result_axis_tready)
);

endmodule