`timescale 1 ns / 1 ps

module weight_axis_v1_0_weight_axis #
(
    parameter integer C_S_AXIS_TDATA_WIDTH = 256
)
(
    output wire [C_S_AXIS_TDATA_WIDTH-1:0] weight_data,
    output wire         weight_valid,
    output wire         weight_last,
    input  wire         weight_ready,

    input wire  S_AXIS_ACLK,
    input wire  S_AXIS_ARESETN,
    output wire S_AXIS_TREADY,
    input wire [C_S_AXIS_TDATA_WIDTH-1:0] S_AXIS_TDATA,
    input wire [(C_S_AXIS_TDATA_WIDTH/8)-1:0] S_AXIS_TSTRB,
    input wire         S_AXIS_TLAST,
    input wire         S_AXIS_TVALID
);

assign weight_data  = S_AXIS_TDATA;
assign weight_valid = S_AXIS_TVALID;
assign weight_last  = S_AXIS_TLAST;

assign S_AXIS_TREADY = weight_ready;

endmodule
