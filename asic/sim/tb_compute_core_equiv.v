`timescale 1ns / 1ps
`include "gemm_asic_cfg.vh"
// ---------------------------------------------------------------------------
// Cycle-by-cycle equivalence check:
//     ref_GemmComputeCore  (original KV260 RTL + behavioural mult_IP)
//  vs GemmComputeCore      (ASIC RTL: no mult_IP, weight shift chain,
//                           FeatureSkew/OutputDeskew split out)
// Both get identical stimulus; every output is compared every cycle.
// Phase 1 = realistic tiles (load 32 weights, stream R feature rows).
// Phase 2 = unconstrained random inputs (the transformation is exact, so the
//           two must match for ANY input sequence, not just legal ones).
// Run with sim/run_equiv.sh (it creates the ref_* copies of the original).
// ---------------------------------------------------------------------------
module tb_compute_core_equiv;

localparam integer N    = `GEMM_N;
localparam integer DW   = `GEMM_DW;
localparam integer RIW  = `GEMM_RIW;
localparam integer PSW  = 2*DW + RIW;
localparam integer AXW  = N*DW;
localparam integer RANDOM_CYCLES = 20000;

reg            clk = 0;
reg            rst_n = 0;
reg            load_phase = 0;
reg  [AXW-1:0] s_data = 0;
reg            s_valid = 0;
reg            s_last = 0;

wire           ref_loaded, dut_loaded;
wire [N*PSW-1:0] ref_pdata, dut_pdata;
wire           ref_pvalid, dut_pvalid, ref_plast, dut_plast;

always #5 clk = ~clk;

ref_GemmComputeCore #(.P_ARRAY_ROWS(N), .P_ARRAY_COLS(N), .P_DATA_WIDTH(DW), .P_ROW_INDEX_WIDTH(RIW)) u_ref (
    .i_clk(clk), .i_rst_n(rst_n),
    .o_weight_tile_loaded(ref_loaded),
    .i_load_weight_phase(load_phase),
    .i_compute_stream_data(s_data), .i_compute_stream_valid(s_valid), .i_compute_stream_last(s_last),
    .o_partial_data(ref_pdata), .o_partial_valid(ref_pvalid), .o_partial_last(ref_plast)
);

GemmComputeCore #(.P_ARRAY_ROWS(N), .P_ARRAY_COLS(N), .P_DATA_WIDTH(DW), .P_ROW_INDEX_WIDTH(RIW)) u_dut (
    .i_clk(clk), .i_rst_n(rst_n),
    .o_weight_tile_loaded(dut_loaded),
    .i_load_weight_phase(load_phase),
    .i_compute_stream_data(s_data), .i_compute_stream_valid(s_valid), .i_compute_stream_last(s_last),
    .o_partial_data(dut_pdata), .o_partial_valid(dut_pvalid), .o_partial_last(dut_plast)
);

// ---------------------------------------------------------------- checker --
integer cycles = 0, mismatches = 0, valid_seen = 0;
reg     check_en = 0;
always @(posedge clk) begin
    if (check_en) begin
        cycles = cycles + 1;
        if (ref_pvalid) valid_seen = valid_seen + 1;
        // control outputs must match every cycle; data only when it is valid
        // (with GEMM_DP_RESET=0 the don't-care data cycles are X after reset)
        if ({ref_pvalid, ref_plast, ref_loaded} !== {dut_pvalid, dut_plast, dut_loaded} ||
            (ref_pvalid === 1'b1 && ref_pdata !== dut_pdata)) begin
            mismatches = mismatches + 1;
            if (mismatches <= 10)
                $display("[%0t] MISMATCH valid %b/%b last %b/%b loaded %b/%b\n   ref=%h\n   dut=%h",
                         $time, ref_pvalid, dut_pvalid, ref_plast, dut_plast, ref_loaded, dut_loaded,
                         ref_pdata, dut_pdata);
        end
    end
end

// --------------------------------------------------------------- stimulus --
function [AXW-1:0] rand_word;
    input dummy;
    integer k;
    begin
        for (k = 0; k < AXW; k = k + 32)
            rand_word[k +: 32] = $random;
    end
endfunction

task drive_idle;
    begin
        @(negedge clk);
        load_phase = 0; s_valid = 0; s_last = 0; s_data = rand_word(0);
    end
endtask

task drive_tile;
    input integer rows;
    integer k;
    begin
        // weight load: one-cycle load_phase pulse, then N weight words
        @(negedge clk); load_phase = 1; s_valid = 0; s_last = 0;
        for (k = 0; k < N; k = k + 1) begin
            @(negedge clk); load_phase = 0;
            s_valid = 1; s_data = rand_word(0); s_last = (k == N-1);
        end
        repeat (3) drive_idle;
        // feature stream
        for (k = 0; k < rows; k = k + 1) begin
            @(negedge clk);
            s_valid = 1; s_data = rand_word(0); s_last = (k == rows-1);
        end
        // let the pipeline drain (latency = 2N + N + a few)
        repeat (3*N + 8) drive_idle;
    end
endtask

integer t;
initial begin
    $display("tb_compute_core_equiv: N=%0d DW=%0d PSW=%0d GEMM_DP_RESET=%0d", N, DW, PSW, `GEMM_DP_RESET);
    repeat (5) @(negedge clk);
    rst_n = 1;
    repeat (2) @(negedge clk);
    check_en = 1;

    // Phase 1: realistic tiles, various row counts
    drive_tile(1);
    drive_tile(N);
    drive_tile(N+7);
    drive_tile(3);
    for (t = 0; t < 10; t = t + 1)
        drive_tile(1 + ($random & 63));

    // Phase 2: unconstrained random
    for (t = 0; t < RANDOM_CYCLES; t = t + 1) begin
        @(negedge clk);
        load_phase = (($random & 31) == 0);
        s_valid    = $random;
        s_last     = (($random & 15) == 0);
        s_data     = rand_word(0);
    end
    repeat (3*N + 8) drive_idle;

    $display("checked %0d cycles, %0d with valid output, %0d mismatches", cycles, valid_seen, mismatches);
    if (mismatches == 0 && valid_seen > 0) $display("EQUIVALENCE PASS");
    else                                    $display("EQUIVALENCE FAIL");
    $finish;
end

endmodule
