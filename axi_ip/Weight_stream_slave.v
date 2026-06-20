module Weight_stream_slave #
(
    parameter integer C_weight_axis_TDATA_WIDTH = 256
)
(
    output wire [C_weight_axis_TDATA_WIDTH-1:0] weight_data,
    output wire         weight_valid,
    output wire         weight_last,
    input  wire         weight_ready,

    input wire  weight_axis_aclk,
    input wire  weight_axis_aresetn,
    output wire weight_axis_tready,
    input wire [C_weight_axis_TDATA_WIDTH-1:0] weight_axis_tdata,
    input wire [(C_weight_axis_TDATA_WIDTH/8)-1:0] weight_axis_tstrb,
    input wire         weight_axis_tlast,
    input wire         weight_axis_tvalid
);

weight_axis_v1_0_weight_axis #(
    .C_S_AXIS_TDATA_WIDTH(C_weight_axis_TDATA_WIDTH)
)
u_weight_stream_slave_axis
(
    .weight_data(weight_data),
    .weight_valid(weight_valid),
    .weight_last(weight_last),
    .weight_ready(weight_ready),

    .S_AXIS_ACLK(weight_axis_aclk),
    .S_AXIS_ARESETN(weight_axis_aresetn),
    .S_AXIS_TREADY(weight_axis_tready),
    .S_AXIS_TDATA(weight_axis_tdata),
    .S_AXIS_TSTRB(weight_axis_tstrb),
    .S_AXIS_TLAST(weight_axis_tlast),
    .S_AXIS_TVALID(weight_axis_tvalid)
);

endmodule
