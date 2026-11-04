`timescale 1ns / 1ps
// Behavioural stand-in for the Xilinx mult_gen IP used by the ORIGINAL
// (KV260) ProcessingElement: signed 8x8 -> 16, one pipeline register.
// Only needed to simulate the original RTL outside Vivado.
module mult_IP (
    input                    CLK,
    input  signed [7:0]      A,
    input  signed [7:0]      B,
    output reg signed [15:0] P
);
always @(posedge CLK) P <= A * B;
endmodule
