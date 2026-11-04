`timescale 1ns/1ps
// ProcessingElementRow: RTL (rtl_asic/PE_row.v) and a gate netlist renamed to
// ProcessingElementRow_gl get the same random inputs every cycle; every
// output bit the RTL knows (not x) must match. Prints the PE/bit that differ.
module tb_row_equiv;
localparam N = `GEMM_N, DW = `GEMM_DW, PSW = 2*`GEMM_DW + `GEMM_RIW;
reg clk = 0, rst_n = 0, sen = 0, ld = 0;
reg  [N*DW-1:0]  win;  reg [DW-1:0] fin;  reg [N*PSW-1:0] pin;
wire [N*DW-1:0]  wo_r, wo_g;
wire [N*PSW-1:0] po_r, po_g;
ProcessingElementRow    r (.i_clk(clk), .i_rst_n(rst_n), .i_weight_shift_en(sen), .i_weight_load(ld),
                           .i_weight_shift_in(win), .o_weight_shift_out(wo_r), .i_feature_value(fin),
                           .i_partial_sum_vector(pin), .o_partial_sum_vector(po_r));
ProcessingElementRow_gl g (.i_clk(clk), .i_rst_n(rst_n), .i_weight_shift_en(sen), .i_weight_load(ld),
                           .i_weight_shift_in(win), .o_weight_shift_out(wo_g), .i_feature_value(fin),
                           .i_partial_sum_vector(pin), .o_partial_sum_vector(po_g));
always #5 clk = ~clk;
integer cyc = 0, bad = 0, i, seed = 1;
integer bp [0:N*PSW-1];
integer bw [0:N*DW-1];
initial begin
    for (i = 0; i < N*PSW; i = i + 1) bp[i] = 0;
    for (i = 0; i < N*DW;  i = i + 1) bw[i] = 0;
    win = 0; fin = 0; pin = 0;
    repeat (3) @(negedge clk);
    rst_n = 1;
    repeat (`NCYC) begin
        @(negedge clk);
        for (i = 0; i < N*PSW; i = i + 1)
            if (po_r[i] !== 1'bx && po_r[i] !== po_g[i]) begin bp[i] = bp[i] + 1; bad = bad + 1; end
        for (i = 0; i < N*DW; i = i + 1)
            if (wo_r[i] !== 1'bx && wo_r[i] !== wo_g[i]) begin bw[i] = bw[i] + 1; bad = bad + 1; end
        sen = $random(seed); ld = ($random(seed) % 8) == 0; fin = $random(seed);
        for (i = 0; i < N; i = i + 1) begin
            win[i*DW +: DW] = $random(seed);
            pin[i*PSW +: PSW] = $random(seed);
        end
        cyc = cyc + 1;
    end
    for (i = 0; i < N*PSW; i = i + 1) if (bp[i]) $display("psum PE %0d bit %0d: %0d cycles", i/PSW, i%PSW, bp[i]);
    for (i = 0; i < N*DW;  i = i + 1) if (bw[i]) $display("weight out PE %0d bit %0d: %0d cycles", i/DW, i%DW, bw[i]);
    $display("cycles=%0d mismatching_bits=%0d", cyc, bad);
    $display("ROW_EQUIV %s", bad == 0 ? "PASS" : "FAIL");
    $finish;
end
endmodule
