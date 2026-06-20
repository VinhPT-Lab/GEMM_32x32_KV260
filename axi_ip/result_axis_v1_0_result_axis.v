`timescale 1 ns / 1 ps

module result_axis_v1_0_result_axis #
(
    parameter integer C_M_AXIS_TDATA_WIDTH = 256
)
(
    // From MM_ultra
    input wire [C_M_AXIS_TDATA_WIDTH-1:0] result_data,
    input wire         result_valid,
    input wire         result_last,
    output wire        result_ready,

    // AXI Stream Master
    input wire  M_AXIS_ACLK,
    input wire  M_AXIS_ARESETN,

    output wire                         M_AXIS_TVALID,
    output wire [C_M_AXIS_TDATA_WIDTH-1:0] M_AXIS_TDATA,
    output wire [(C_M_AXIS_TDATA_WIDTH/8)-1:0] M_AXIS_TSTRB,
    output wire                         M_AXIS_TLAST,
    input wire                          M_AXIS_TREADY
);

assign M_AXIS_TDATA  = result_data;
assign M_AXIS_TVALID = result_valid;
assign M_AXIS_TLAST  = result_last;

assign result_ready  = M_AXIS_TREADY;

assign M_AXIS_TSTRB = {(C_M_AXIS_TDATA_WIDTH/8){1'b1}};

endmodule
