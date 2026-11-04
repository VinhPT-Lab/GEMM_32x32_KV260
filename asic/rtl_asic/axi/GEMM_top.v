`timescale 1ns / 1ps
`include "gemm_asic_cfg.vh"
// ---------------------------------------------------------------------------
// GEMM_top (ASIC) - the GEMM core as an AXI accelerator IP:
//   AXI4-Lite control + feature/weight AXI4-Stream in + result AXI4-Stream out
//   = GemmAxiShell (rtl_asic/axi) + GemmAccelerator (rtl_asic, core_v11).
//
// Drop-in replacement for rtl/GEMM_top.v of the KV260 repo: same module
// name, same ports and parameters (plus an irq output), registers 0x00..0x0C
// as on the KV260, so the original testbench (tb_GEMM_2_job_64x64.sv) and the
// KV260 driver use it unchanged. The IP itself has a 6-bit AXI4-Lite address
// for the new registers 0x10..0x24 (AxiLiteControlRegs); the KV260 testbench
// instantiates it with 4 bits and simply cannot reach them.
// sim/run_system.sh WRAP=thin|reg builds it instead of the KV260 wrapper.
//
// The compute core is not touched. It gets NO parameter overrides: in the
// hardened IP it is built from the defaults in gemm_asic_cfg.vh (and its
// rows are hard macros, which have no parameters). The parameters below
// exist only so the KV260 testbench can instantiate this module as before;
// a simulation stops at time 0 if they disagree with the core that is built.
// (Synthesis builds the defaults, so the check is simulation-only: a
// generate branch with a missing module would also stop Verilator's lint,
// which resolves every instance before it evaluates generate conditions.)
// ---------------------------------------------------------------------------
module GEMM_top
#(
    parameter integer P_AXI_LITE_DATA_WIDTH  = 32,
    parameter integer P_AXI_LITE_ADDR_WIDTH  = 6,
    parameter integer P_ARRAY_SIZE           = 32,
    parameter integer P_DATA_WIDTH           = 8,
    parameter integer P_SHIFT_WIDTH          = 10,
    parameter integer P_WEIGHT_BUFFER_DEPTH  = `GEMM_W_DEPTH,
    parameter integer P_FEATURE_BUFFER_DEPTH = `GEMM_F_DEPTH,
    parameter integer P_OUTPUT_BUFFER_DEPTH  = `GEMM_O_DEPTH,
    parameter integer P_ACCUM_WIDTH          = 32,
    parameter integer P_ROW_COUNT_WIDTH      = 9,
    parameter integer P_K_BLOCK_COUNT_WIDTH  = 5,
    parameter integer P_N_BLOCK_COUNT_WIDTH  = 5,
    parameter integer P_AXIS_REG             = `GEMM_AXIS_REG,
    parameter integer P_AXIS_CG              = `GEMM_AXIS_CG
)
(
    // ---- AXI4-Lite control
    input                                   S_AXI_ACLK,
    input                                   S_AXI_ARESETN,
    input  [P_AXI_LITE_ADDR_WIDTH-1:0]      S_AXI_AWADDR,
    input  [2:0]                            S_AXI_AWPROT,
    input                                   S_AXI_AWVALID,
    output                                  S_AXI_AWREADY,
    input  [P_AXI_LITE_DATA_WIDTH-1:0]      S_AXI_WDATA,
    input  [(P_AXI_LITE_DATA_WIDTH/8)-1:0]  S_AXI_WSTRB,
    input                                   S_AXI_WVALID,
    output                                  S_AXI_WREADY,
    output [1:0]                            S_AXI_BRESP,
    output                                  S_AXI_BVALID,
    input                                   S_AXI_BREADY,
    input  [P_AXI_LITE_ADDR_WIDTH-1:0]      S_AXI_ARADDR,
    input  [2:0]                            S_AXI_ARPROT,
    input                                   S_AXI_ARVALID,
    output                                  S_AXI_ARREADY,
    output [P_AXI_LITE_DATA_WIDTH-1:0]      S_AXI_RDATA,
    output [1:0]                            S_AXI_RRESP,
    output                                  S_AXI_RVALID,
    input                                   S_AXI_RREADY,
    output                                  irq,            // job done / error (registers 0x10, 0x14)

    // ---- feature AXI4-Stream slave
    output                                          feature_axis_tready,
    input  [P_ARRAY_SIZE*P_DATA_WIDTH-1:0]          feature_axis_tdata,
    input  [(P_ARRAY_SIZE*P_DATA_WIDTH/8)-1:0]      feature_axis_tstrb,
    input                                           feature_axis_tlast,
    input                                           feature_axis_tvalid,

    // ---- weight AXI4-Stream slave
    output                                          weight_axis_tready,
    input  [P_ARRAY_SIZE*P_DATA_WIDTH-1:0]          weight_axis_tdata,
    input  [(P_ARRAY_SIZE*P_DATA_WIDTH/8)-1:0]      weight_axis_tstrb,
    input                                           weight_axis_tlast,
    input                                           weight_axis_tvalid,

    // ---- result AXI4-Stream master
    output                                          result_axis_tvalid,
    output [P_ARRAY_SIZE*P_DATA_WIDTH-1:0]          result_axis_tdata,
    output [(P_ARRAY_SIZE*P_DATA_WIDTH/8)-1:0]      result_axis_tstrb,
    output                                          result_axis_tlast,
    input                                           result_axis_tready
);

localparam integer LP_W = P_ARRAY_SIZE * P_DATA_WIDTH;

// ---------------------------------------------------------------------------
// the parameters must describe the core that is really built: GemmAccelerator
// with its defaults (array 32 x 8 bit, shift 10, accumulator 32, counters
// 9/5/5, depths from gemm_asic_cfg.vh) and a 32-bit AXI4-Lite with a 6-bit
// address (the IP) or 4-bit (the KV260 testbench, registers 0x00..0x0C only)
// ---------------------------------------------------------------------------
`ifndef SYNTHESIS
initial begin
    if (P_ARRAY_SIZE != 32 || P_DATA_WIDTH != 8 ||
        P_WEIGHT_BUFFER_DEPTH != `GEMM_W_DEPTH || P_FEATURE_BUFFER_DEPTH != `GEMM_F_DEPTH ||
        P_OUTPUT_BUFFER_DEPTH != `GEMM_O_DEPTH ||
        P_SHIFT_WIDTH != 10 || P_ACCUM_WIDTH != 32 || P_ROW_COUNT_WIDTH != 9 ||
        P_K_BLOCK_COUNT_WIDTH != 5 || P_N_BLOCK_COUNT_WIDTH != 5 ||
        P_AXI_LITE_DATA_WIDTH != 32 ||
        (P_AXI_LITE_ADDR_WIDTH != 4 && P_AXI_LITE_ADDR_WIDTH != 6)) begin
        $display("ERROR: GEMM_top (ASIC) parameters disagree with the core that is built: array %0d x %0d, depths W%0d F%0d O%0d; expected 32 x 8, W%0d F%0d O%0d",
                 P_ARRAY_SIZE, P_DATA_WIDTH, P_WEIGHT_BUFFER_DEPTH, P_FEATURE_BUFFER_DEPTH,
                 P_OUTPUT_BUFFER_DEPTH, `GEMM_W_DEPTH, `GEMM_F_DEPTH, `GEMM_O_DEPTH);
        $finish;
    end
end
`endif

// ---------------------------------------------------------------------------
wire                w_core_rst_n;
wire [9:0]          w_cfg_shift;
wire [8:0]          w_cfg_row_count;
wire [4:0]          w_cfg_k_block_count;
wire [4:0]          w_cfg_n_block_count;
wire                w_feature_valid, w_feature_last, w_feature_ready;
wire [LP_W-1:0]     w_feature_data;
wire                w_weight_valid, w_weight_last, w_weight_ready;
wire [LP_W-1:0]     w_weight_data;
wire                w_result_valid, w_result_last, w_result_ready;
wire [LP_W-1:0]     w_result_data;

GemmAxiShell #(
    .P_AXI_LITE_DATA_WIDTH (P_AXI_LITE_DATA_WIDTH),
    .P_AXI_LITE_ADDR_WIDTH (P_AXI_LITE_ADDR_WIDTH),
    .P_STREAM_WIDTH        (LP_W),
    .P_AXIS_REG            (P_AXIS_REG),
    .P_AXIS_CG             (P_AXIS_CG)
) u_axi_shell (
    .S_AXI_ACLK    (S_AXI_ACLK),
    .S_AXI_ARESETN (S_AXI_ARESETN),
    .S_AXI_AWADDR  (S_AXI_AWADDR),
    .S_AXI_AWPROT  (S_AXI_AWPROT),
    .S_AXI_AWVALID (S_AXI_AWVALID),
    .S_AXI_AWREADY (S_AXI_AWREADY),
    .S_AXI_WDATA   (S_AXI_WDATA),
    .S_AXI_WSTRB   (S_AXI_WSTRB),
    .S_AXI_WVALID  (S_AXI_WVALID),
    .S_AXI_WREADY  (S_AXI_WREADY),
    .S_AXI_BRESP   (S_AXI_BRESP),
    .S_AXI_BVALID  (S_AXI_BVALID),
    .S_AXI_BREADY  (S_AXI_BREADY),
    .S_AXI_ARADDR  (S_AXI_ARADDR),
    .S_AXI_ARPROT  (S_AXI_ARPROT),
    .S_AXI_ARVALID (S_AXI_ARVALID),
    .S_AXI_ARREADY (S_AXI_ARREADY),
    .S_AXI_RDATA   (S_AXI_RDATA),
    .S_AXI_RRESP   (S_AXI_RRESP),
    .S_AXI_RVALID  (S_AXI_RVALID),
    .S_AXI_RREADY  (S_AXI_RREADY),
    .irq           (irq),

    .feature_axis_tready (feature_axis_tready),
    .feature_axis_tdata  (feature_axis_tdata),
    .feature_axis_tstrb  (feature_axis_tstrb),
    .feature_axis_tlast  (feature_axis_tlast),
    .feature_axis_tvalid (feature_axis_tvalid),

    .weight_axis_tready  (weight_axis_tready),
    .weight_axis_tdata   (weight_axis_tdata),
    .weight_axis_tstrb   (weight_axis_tstrb),
    .weight_axis_tlast   (weight_axis_tlast),
    .weight_axis_tvalid  (weight_axis_tvalid),

    .result_axis_tvalid  (result_axis_tvalid),
    .result_axis_tdata   (result_axis_tdata),
    .result_axis_tstrb   (result_axis_tstrb),
    .result_axis_tlast   (result_axis_tlast),
    .result_axis_tready  (result_axis_tready),

    .o_core_rst_n        (w_core_rst_n),
    .o_cfg_shift         (w_cfg_shift),
    .o_cfg_row_count     (w_cfg_row_count),
    .o_cfg_k_block_count (w_cfg_k_block_count),
    .o_cfg_n_block_count (w_cfg_n_block_count),
    .o_feature_valid     (w_feature_valid),
    .o_feature_last      (w_feature_last),
    .i_feature_ready     (w_feature_ready),
    .o_feature_data      (w_feature_data),
    .o_weight_valid      (w_weight_valid),
    .o_weight_last       (w_weight_last),
    .i_weight_ready      (w_weight_ready),
    .o_weight_data       (w_weight_data),
    .i_result_valid      (w_result_valid),
    .o_result_ready      (w_result_ready),
    .i_result_last       (w_result_last),
    .i_result_data       (w_result_data)
);

// the compute core, defaults only (see the header)
GemmAccelerator u_gemm_accelerator (
    .i_clk               (S_AXI_ACLK),
    .i_rst_n             (w_core_rst_n),
    .i_cfg_shift         (w_cfg_shift),
    .i_cfg_row_count     (w_cfg_row_count),
    .i_cfg_k_block_count (w_cfg_k_block_count),
    .i_cfg_n_block_count (w_cfg_n_block_count),
    .i_feature_valid     (w_feature_valid),
    .i_feature_last      (w_feature_last),
    .o_feature_ready     (w_feature_ready),
    .i_feature_data      (w_feature_data),
    .i_weight_valid      (w_weight_valid),
    .i_weight_last       (w_weight_last),
    .o_weight_ready      (w_weight_ready),
    .i_weight_data       (w_weight_data),
    .o_result_valid      (w_result_valid),
    .i_result_ready      (w_result_ready),
    .o_result_last       (w_result_last),
    .o_result_data       (w_result_data)
);

endmodule
