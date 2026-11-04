`timescale 1ns / 1ps
// RightShifter (rtl_asic) against the original module (RightShifter_ref):
// every shift amount 0..1023 with random data plus values next to the
// rounding and saturation boundaries. Prints RS_EQUIV PASS / FAIL.
module tb_right_shifter_equiv;
    reg  [9:0]  s;
    reg  [31:0] d;
    wire [7:0]  o_new, o_ref;
    integer i, k, sh, errors, cases;
    reg signed [31:0] base;
    integer specials [0:13];

    RightShifter     #(.P_INPUT_WIDTH(32), .P_OUTPUT_WIDTH(8), .P_SHIFT_WIDTH(10)) dut (.i_shift_amount(s), .i_data(d), .o_data(o_new));
    RightShifter_ref #(.P_INPUT_WIDTH(32), .P_OUTPUT_WIDTH(8), .P_SHIFT_WIDTH(10)) ref0 (.i_shift_amount(s), .i_data(d), .o_data(o_ref));

    task check;
        begin
            #1;
            cases = cases + 1;
            if (o_new !== o_ref) begin
                errors = errors + 1;
                if (errors <= 10) $display("MISMATCH shift=%0d data=%h new=%h ref=%h", s, d, o_new, o_ref);
            end
        end
    endtask

    initial begin
        specials[0] = 0;    specials[1] = 1;    specials[2] = -1;   specials[3] = 127;
        specials[4] = 128;  specials[5] = -128; specials[6] = -129; specials[7] = -130;
        specials[8] = 126;  specials[9] = 255;  specials[10] = 256; specials[11] = -256;
        specials[12] = 32'h7fffffff; specials[13] = 32'h80000000;
        errors = 0; cases = 0;
        for (i = 0; i < 1024; i = i + 1) begin
            s = i;
            for (k = 0; k < 200; k = k + 1) begin d = $random; check; end
            for (k = 0; k < 14; k = k + 1)
                for (sh = 0; sh < 32; sh = sh + 1) begin
                    base = specials[k] <<< sh;
                    d = base;                            check;
                    d = base + ((32'd1 << sh) - 1);      check;
                    d = base - 1;                        check;
                    d = base + 1;                        check;
                    d = base + (sh > 0 ? (32'd1 << (sh - 1)) : 0); check;
                end
        end
        if (errors == 0) $display("RS_EQUIV PASS (%0d cases)", cases);
        else             $display("RS_EQUIV FAIL (%0d of %0d cases differ)", errors, cases);
        $finish;
    end
endmodule
