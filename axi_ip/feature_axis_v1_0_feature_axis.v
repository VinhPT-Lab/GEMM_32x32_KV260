`timescale 1 ns / 1 ps

module feature_axis_v1_0_feature_axis #
(
    parameter integer C_S_AXIS_TDATA_WIDTH = 256
)
(
    output wire [C_S_AXIS_TDATA_WIDTH-1:0] feature_data,
    output wire         feature_valid,
    output wire         feature_last,
    input  wire         feature_ready,

    input wire  S_AXIS_ACLK,
    input wire  S_AXIS_ARESETN,
    output wire S_AXIS_TREADY,
    input wire [C_S_AXIS_TDATA_WIDTH-1:0] S_AXIS_TDATA,
    input wire [(C_S_AXIS_TDATA_WIDTH/8)-1:0] S_AXIS_TSTRB,
    input wire         S_AXIS_TLAST,
    input wire         S_AXIS_TVALID
);

assign feature_data  = S_AXIS_TDATA;
assign feature_valid = S_AXIS_TVALID;
assign feature_last  = S_AXIS_TLAST;

assign S_AXIS_TREADY = feature_ready;

endmodule
