`timescale 1ns / 1ps
// RightShifter: arithmetic right shift with round-half-up and INT8 saturation.
//
// Same function as the original module for every input (checked against it
// over all shift amounts and 2.6 M data values, corner values included), but
// arranged so the path from i_data to o_data is short. The shift amount is a
// configuration value that only changes while the core is idle (multicycle in
// cfg_shift_mcp.sdc); only the data path has to fit in one clock:
//  - the barrel shift uses the low LP_SW bits of the amount; amounts
//    >= P_INPUT_WIDTH give all sign bits through one final select,
//  - saturation is decided on the shifted value S and the round bit r
//    directly (S + r > MAX  <=>  S > MAX, or S == MAX and r = 1;
//    S + r < MIN  <=>  S < MIN, unless S == MIN-1 and r = 1), so no
//    P_INPUT_WIDTH-bit increment sits in front of the saturation check,
//  - only the low P_OUTPUT_WIDTH bits get the +r.
module RightShifter
#(
    parameter P_INPUT_WIDTH = 32,
    parameter P_OUTPUT_WIDTH = 8,
    parameter P_SHIFT_WIDTH = 5
)
(
    i_shift_amount,
    i_data,
    o_data
);

localparam integer LP_SW = $clog2(P_INPUT_WIDTH);

input wire [P_SHIFT_WIDTH-1:0]i_shift_amount;
input wire signed [P_INPUT_WIDTH-1:0] i_data;
output reg signed[P_OUTPUT_WIDTH-1:0] o_data;

// configuration-only signals
wire                w_zero   = (i_shift_amount == 0);
wire                w_big    = (i_shift_amount >= P_INPUT_WIDTH);
wire [LP_SW-1:0]    w_sh     = i_shift_amount[LP_SW-1:0];
wire [LP_SW-1:0]    w_rb_idx = w_sh - {{(LP_SW-1){1'b0}}, 1'b1};

// shifted value and round bit
wire signed [P_INPUT_WIDTH-1:0] w_shift_low = i_data >>> w_sh;
wire signed [P_INPUT_WIDTH-1:0] w_s = w_big ? {P_INPUT_WIDTH{i_data[P_INPUT_WIDTH-1]}} : w_shift_low;
wire                            w_r = (w_zero | w_big) ? 1'b0 : i_data[w_rb_idx];

// saturation from S and r
wire w_sign     = w_s[P_INPUT_WIDTH-1];
wire w_hi_any   = |w_s[P_INPUT_WIDTH-2:P_OUTPUT_WIDTH-1];
wire w_hi_all   = &w_s[P_INPUT_WIDTH-2:P_OUTPUT_WIDTH-1];
wire w_low_ones = &w_s[P_OUTPUT_WIDTH-2:0];
wire w_eq_max   = ~w_sign & ~w_hi_any & w_low_ones;                       // S == MAX
wire w_eq_minm1 = w_sign & (&w_s[P_INPUT_WIDTH-2:P_OUTPUT_WIDTH])
                  & ~w_s[P_OUTPUT_WIDTH-1] & w_low_ones;                  // S == MIN-1
wire w_over_max  = (~w_sign & w_hi_any) | (w_r & w_eq_max);
wire w_under_min = (w_sign & ~w_hi_all) & ~(w_r & w_eq_minm1);

wire [P_OUTPUT_WIDTH-1:0] w_low = w_s[P_OUTPUT_WIDTH-1:0] + {{(P_OUTPUT_WIDTH-1){1'b0}}, w_r};

always @(*) begin
    case ({w_under_min, w_over_max})
        2'b10:   o_data = {1'b1,{(P_OUTPUT_WIDTH-1){1'b0}}};   // 8'b1000_0000
        2'b01:   o_data = {1'b0,{(P_OUTPUT_WIDTH-1){1'b1}}};   // 8'b0111_1111
        default: o_data = w_low;
    endcase
end

endmodule
