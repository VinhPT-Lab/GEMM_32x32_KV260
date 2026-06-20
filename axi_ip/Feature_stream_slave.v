`timescale 1 ns / 1 ps

module Feature_stream_slave #
(
    parameter integer C_feature_axis_TDATA_WIDTH = 256
)
(
    // Export sang GEMM_core
    output wire [C_feature_axis_TDATA_WIDTH-1:0] feature_data,
    output wire         feature_valid,
    output wire         feature_last,
    input  wire         feature_ready,

    // AXI Stream Slave
    input wire  feature_axis_aclk,
    input wire  feature_axis_aresetn,
    output wire feature_axis_tready,
    input wire [C_feature_axis_TDATA_WIDTH-1:0] feature_axis_tdata,
    input wire [(C_feature_axis_TDATA_WIDTH/8)-1:0] feature_axis_tstrb,
    input wire feature_axis_tlast,
    input wire feature_axis_tvalid
);

feature_axis_v1_0_feature_axis #(
    .C_S_AXIS_TDATA_WIDTH(C_feature_axis_TDATA_WIDTH)
)
u_feature_stream_slave_axis
(
    .feature_data(feature_data),
    .feature_valid(feature_valid),
    .feature_last(feature_last),
    .feature_ready(feature_ready),

    .S_AXIS_ACLK(feature_axis_aclk),
    .S_AXIS_ARESETN(feature_axis_aresetn),
    .S_AXIS_TREADY(feature_axis_tready),
    .S_AXIS_TDATA(feature_axis_tdata),
    .S_AXIS_TSTRB(feature_axis_tstrb),
    .S_AXIS_TLAST(feature_axis_tlast),
    .S_AXIS_TVALID(feature_axis_tvalid)
);

endmodule
