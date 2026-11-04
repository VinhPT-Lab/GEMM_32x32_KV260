`timescale 1ns / 1ps
// Random-data testbench for one hardened block (ProcessingElement, COLS = 1, or
// ProcessingElementRow, COLS = 32): the gate netlist (dut) and the RTL (ref_*) run
// side by side; outputs are compared every cycle once the pipeline is full.
// Weights: a new random tile is shifted in and loaded every 64 cycles; features and
// partial sums are random every cycle. One MAC per PE per cycle.
// The VCD (depth 1 of dut) covers cycles [W0, W0+WN).
module tb_block_rand;
    parameter COLS = 32, W0 = 200, WN = 1000, NCYC = 1300;
    localparam DW = 8, PSW = 21;
    reg clk = 0, rst_n = 0, sh = 0, ld = 0;
    reg [COLS*DW-1:0] w;
    reg [DW-1:0] f;
    reg [COLS*PSW-1:0] ps;
    wire [COLS*DW-1:0] wo_d, wo_r;
    wire [COLS*PSW-1:0] po_d, po_r;
`ifdef ROW
    ProcessingElementRow dut (.i_clk(clk), .i_rst_n(rst_n), .i_weight_shift_en(sh), .i_weight_load(ld),
        .i_weight_shift_in(w), .o_weight_shift_out(wo_d), .i_feature_value(f),
        .i_partial_sum_vector(ps), .o_partial_sum_vector(po_d));
    ref_ProcessingElementRow #(.P_ARRAY_COLS(32), .P_DATA_WIDTH(8), .P_ROW_INDEX_WIDTH(5), .P_DATAPATH_RESET(0)) ref0 (
        .i_clk(clk), .i_rst_n(rst_n), .i_weight_shift_en(sh), .i_weight_load(ld),
        .i_weight_shift_in(w), .o_weight_shift_out(wo_r), .i_feature_value(f),
        .i_partial_sum_vector(ps), .o_partial_sum_vector(po_r));
`else
    wire [DW-1:0] fo_d, fo_r;
    ProcessingElement dut (.i_clk(clk), .i_rst_n(rst_n), .i_weight_shift_en(sh), .i_weight_load(ld),
        .i_weight_shift_in(w), .o_weight_shift_out(wo_d), .i_feature_value(f), .i_partial_sum(ps),
        .o_feature_value(fo_d), .o_partial_sum(po_d));
    ref_ProcessingElement #(.P_DATA_WIDTH(8), .P_ROW_INDEX_WIDTH(5), .P_DATAPATH_RESET(0)) ref0 (
        .i_clk(clk), .i_rst_n(rst_n), .i_weight_shift_en(sh), .i_weight_load(ld),
        .i_weight_shift_in(w), .o_weight_shift_out(wo_r), .i_feature_value(f), .i_partial_sum(ps),
        .o_feature_value(fo_r), .o_partial_sum(po_r));
`endif
    always #5 clk = ~clk;
    integer cycle = 0, errs = 0, checks = 0, i, seed = 12345;
    always @(posedge clk) cycle <= cycle + 1;
    task rnd; begin
        for (i = 0; i < COLS; i = i + 1) begin w[i*DW +: DW] = $random(seed); ps[i*PSW +: PSW] = $random(seed); end
        f = $random(seed);
    end endtask
    initial begin
        w = 0; f = 0; ps = 0;
        repeat (4) @(negedge clk); rst_n = 1;
        while (cycle < NCYC) begin
            @(negedge clk);
            rnd;
            sh = (cycle % 64) == 0; ld = (cycle % 64) == 1;
        end
        $display("BLOCK_RAND COLS=%0d cycles=%0d checks=%0d mismatches=%0d %s", COLS, cycle, checks, errs, errs == 0 ? "PASS" : "FAIL");
        $finish;
    end
    // compare after the pipeline has seen defined data (2-stage PE, COLS PEs on the feature lane)
    always @(negedge clk) if (rst_n && cycle > COLS + 70) begin
        checks = checks + 1;
        if (po_d !== po_r || wo_d !== wo_r) begin
            errs = errs + 1;
            if (errs < 5) $display("MISMATCH cycle=%0d", cycle);
        end
    end
    initial begin
        $dumpfile("win.vcd");
        wait (cycle == W0); @(negedge clk);
        $dumpvars(1, dut);
        $display("VCD_START cycle=%0d", cycle);
        wait (cycle == W0 + WN); @(negedge clk);
        $dumpoff; $dumpflush;
        $display("VCD_END cycle=%0d", cycle);
    end
endmodule
