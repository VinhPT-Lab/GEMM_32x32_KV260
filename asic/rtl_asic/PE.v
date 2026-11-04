`timescale 1ns / 1ps
// ---------------------------------------------------------------------------
// ProcessingElement  (ASIC version)
//
// Changes vs. the KV260 version:
//  1. Xilinx mult_IP is gone. The multiply is plain signed Verilog followed by
//     ONE register, which is exactly the latency mult_IP was configured for
//     (LP_MULT_LATENCY = 1). PE latency stays 2 cycles, so every alignment
//     constant upstream/downstream is unchanged.
//  2. Weights arrive through a vertical shift chain
//        i_weight_shift_in -> r_weight_shift -> o_weight_shift_out
//     instead of a 32x32x8 = 8192-bit parallel bus from GemmComputeCore.
//     i_weight_load copies r_weight_shift into the active weight register,
//     the same moment the old design latched the parallel bus. Cycle
//     behaviour is identical; only the wiring became local.
//  3. P_DATAPATH_RESET = 0 drops the async reset on pure datapath flops
//     (feature, product, psum). Smaller cells and a lighter reset tree.
//     Keep it at 1 until the equivalence test passes, then try 0.
// ---------------------------------------------------------------------------
module ProcessingElement
#(
    parameter P_DATA_WIDTH      = 8,
    parameter P_ROW_INDEX_WIDTH = 5,
    parameter P_DATAPATH_RESET  = 1
)
(
    input                                                   i_clk,
    input                                                   i_rst_n,
    input                                                   i_weight_shift_en,
    input                                                   i_weight_load,
    input      signed [P_DATA_WIDTH-1:0]                    i_weight_shift_in,
    output     signed [P_DATA_WIDTH-1:0]                    o_weight_shift_out,
    input      signed [P_DATA_WIDTH-1:0]                    i_feature_value,
    input      signed [2*P_DATA_WIDTH+P_ROW_INDEX_WIDTH-1:0] i_partial_sum,
    output reg signed [P_DATA_WIDTH-1:0]                    o_feature_value,
    output reg signed [2*P_DATA_WIDTH+P_ROW_INDEX_WIDTH-1:0] o_partial_sum
);
localparam integer LP_PSUM_WIDTH = 2*P_DATA_WIDTH + P_ROW_INDEX_WIDTH;
localparam integer LP_PROD_WIDTH = 2*P_DATA_WIDTH;

reg  signed [P_DATA_WIDTH-1:0]  r_weight_shift;   // shift-chain stage
reg  signed [P_DATA_WIDTH-1:0]  r_weight_value;   // active (stationary) weight
reg  signed [LP_PROD_WIDTH-1:0] r_product;        // = old mult_IP output reg
reg  signed [LP_PSUM_WIDTH-1:0] r_partial_sum_d1;

wire signed [LP_PROD_WIDTH-1:0] w_product     = i_feature_value * r_weight_value;
wire signed [LP_PSUM_WIDTH-1:0] w_product_ext = {{(LP_PSUM_WIDTH-LP_PROD_WIDTH){r_product[LP_PROD_WIDTH-1]}}, r_product};

assign o_weight_shift_out = r_weight_shift;

// Weight registers always keep their reset (small, and it keeps gate-level
// simulation free of X before the first tile is loaded).
always @(posedge i_clk or negedge i_rst_n) begin
    if (~i_rst_n) begin
        r_weight_shift <= 0;
        r_weight_value <= 0;
    end
    else begin
        if (i_weight_shift_en)
            r_weight_shift <= i_weight_shift_in;
        if (i_weight_load)
            r_weight_value <= r_weight_shift;
    end
end

generate
    if (P_DATAPATH_RESET) begin : g_dp_rst
        always @(posedge i_clk or negedge i_rst_n) begin
            if (~i_rst_n) begin
                r_product        <= 0;
                r_partial_sum_d1 <= 0;
                o_partial_sum    <= 0;
                o_feature_value  <= 0;
            end
            else begin
                r_product        <= w_product;
                r_partial_sum_d1 <= i_partial_sum;
                o_partial_sum    <= r_partial_sum_d1 + w_product_ext;
                o_feature_value  <= i_feature_value;
            end
        end
    end
    else begin : g_dp_norst
        always @(posedge i_clk) begin
            r_product        <= w_product;
            r_partial_sum_d1 <= i_partial_sum;
            o_partial_sum    <= r_partial_sum_d1 + w_product_ext;
            o_feature_value  <= i_feature_value;
        end
    end
endgenerate

endmodule
