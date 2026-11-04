`timescale 1ns / 1ps
// RightShifter: arithmetic right shift with round-half-up and INT8 saturation
module RightShifter_ref
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

input wire [P_SHIFT_WIDTH-1:0]i_shift_amount;
input wire signed [P_INPUT_WIDTH-1:0] i_data;
output reg signed[P_OUTPUT_WIDTH-1:0] o_data;

wire signed [P_INPUT_WIDTH-1:0] w_shifted_value;
wire signed [P_INPUT_WIDTH-1:0] w_rounded_value;
reg r_round_bit;

always @(*) begin
    if(i_shift_amount == 0)
        r_round_bit = 1'b0;
    else if(i_shift_amount >= P_INPUT_WIDTH)
        r_round_bit = 1'b0;
    else
        r_round_bit = i_data[i_shift_amount-1];
end

assign w_shifted_value = i_data >>> i_shift_amount;
assign w_rounded_value = r_round_bit ? w_shifted_value + 1 : w_shifted_value;

wire w_under_min = w_rounded_value[P_INPUT_WIDTH-1] & (~(& w_rounded_value[P_INPUT_WIDTH-2:P_OUTPUT_WIDTH-1]));
wire w_over_max = (~w_rounded_value[P_INPUT_WIDTH-1]) & (|w_rounded_value[P_INPUT_WIDTH-2:P_OUTPUT_WIDTH-1]);

wire w_under_min_no_shift = i_data[P_INPUT_WIDTH-1] & (~(& i_data[P_INPUT_WIDTH-2:P_OUTPUT_WIDTH-1]));
wire w_over_max_no_shift = (~i_data[P_INPUT_WIDTH-1]) & (|i_data[P_INPUT_WIDTH-2:P_OUTPUT_WIDTH-1]);

always @(*) begin
    if(i_shift_amount == 0)
        case ({w_under_min_no_shift,w_over_max_no_shift})
            2'b10: o_data = {1'b1,{(P_OUTPUT_WIDTH-1){1'b0}}};//o_data = 8'b1000_0000;
            2'b01: o_data = {1'b0,{(P_OUTPUT_WIDTH-1){1'b1}}};//8'b0111_1111;
            default: o_data = i_data;
        endcase
    else begin
        case ({w_under_min,w_over_max})
            2'b10: o_data = {1'b1,{(P_OUTPUT_WIDTH-1){1'b0}}};//o_data = 8'b1000_0000;
            2'b01: o_data = {1'b0,{(P_OUTPUT_WIDTH-1){1'b1}}};//8'b0111_1111;
            default: o_data = w_rounded_value[P_OUTPUT_WIDTH-1:0];
        endcase
    end
end

endmodule
