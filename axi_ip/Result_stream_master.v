`timescale 1 ns / 1 ps

module Result_stream_master #
(
    parameter integer C_result_axis_TDATA_WIDTH = 256
)
(
    // To/From GEMM_core
    input wire [C_result_axis_TDATA_WIDTH-1:0] result_data,
    input wire         result_valid,
    input wire         result_last,
    output wire        result_ready,

    // AXI Stream Master
    input wire result_axis_aclk,
    input wire result_axis_aresetn,

    output wire result_axis_tvalid,
    output wire [C_result_axis_TDATA_WIDTH-1:0] result_axis_tdata,
    output wire [(C_result_axis_TDATA_WIDTH/8)-1:0] result_axis_tstrb,
    output wire result_axis_tlast,
    input wire result_axis_tready
);

result_axis_v1_0_result_axis #(
    .C_M_AXIS_TDATA_WIDTH(C_result_axis_TDATA_WIDTH)
)
u_result_stream_master_axis
(
    .result_data(result_data),
    .result_valid(result_valid),
    .result_last(result_last),
    .result_ready(result_ready),

    .M_AXIS_ACLK(result_axis_aclk),
    .M_AXIS_ARESETN(result_axis_aresetn),

    .M_AXIS_TVALID(result_axis_tvalid),
    .M_AXIS_TDATA(result_axis_tdata),
    .M_AXIS_TSTRB(result_axis_tstrb),
    .M_AXIS_TLAST(result_axis_tlast),
    .M_AXIS_TREADY(result_axis_tready)
);

endmodule
