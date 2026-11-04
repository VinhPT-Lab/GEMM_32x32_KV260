`timescale 1ns / 1ps

module SignedAdder
#(
    parameter integer P_ARRAY_SIZE = 32,
    parameter integer P_DATA_WIDTH = 8
)(
    input  [P_ARRAY_SIZE * P_DATA_WIDTH - 1 : 0] i_addend_a,
    input  [P_ARRAY_SIZE * P_DATA_WIDTH - 1 : 0] i_addend_b,
    output reg [P_ARRAY_SIZE * P_DATA_WIDTH - 1 : 0] o_sum_sat
);
wire [(P_DATA_WIDTH + 1)-1:0] w_lane_sum_ext [P_ARRAY_SIZE-1:0]; // Double sign bit detects positive/negative overflow.
wire [P_DATA_WIDTH - 1:0] w_sum_lane_display [P_ARRAY_SIZE-1:0];
genvar i;

generate
    for(i=0;i<P_ARRAY_SIZE;i=i+1)begin
        assign w_sum_lane_display[i] = o_sum_sat[i*P_DATA_WIDTH +: P_DATA_WIDTH];
    end
endgenerate

generate
    for(i=0;i<P_ARRAY_SIZE;i=i+1)begin
        assign w_lane_sum_ext[i] = {i_addend_a[(i+1)*P_DATA_WIDTH-1],i_addend_a[i *P_DATA_WIDTH +: P_DATA_WIDTH]} 
                                 + {i_addend_b[(i+1)*P_DATA_WIDTH-1],i_addend_b[i *P_DATA_WIDTH +: P_DATA_WIDTH]};
    end
endgenerate
generate
    for(i=0;i<P_ARRAY_SIZE;i=i+1)begin
        always @(*) begin
            case (w_lane_sum_ext[i][P_DATA_WIDTH:P_DATA_WIDTH-1])
                2'b01: o_sum_sat[i * P_DATA_WIDTH +: P_DATA_WIDTH] = {1'b0,{(P_DATA_WIDTH-1){1'b1}}};   
                2'b10: o_sum_sat[i * P_DATA_WIDTH +: P_DATA_WIDTH] = {1'b1,{(P_DATA_WIDTH-1){1'b0}}};   
                default: o_sum_sat[i * P_DATA_WIDTH +: P_DATA_WIDTH] = w_lane_sum_ext[i][P_DATA_WIDTH-1:0];
            endcase
         
        end
    end
endgenerate
endmodule
