/// sta-blackbox
// Port-only view of the sky130 OpenRAM macro used by sram_1r1w
// (SRAM_USE_SKY130_OPENRAM). Lint and synthesis see the ports; STA skips this
// file and takes the macro timing from EXTRA_LIBS. Ports copied from
// libs.ref/sky130_sram_macros/verilog/sky130_sram_2kbyte_1rw1r_32x512_8.v.
(* blackbox *)
module sky130_sram_2kbyte_1rw1r_32x512_8 (
`ifdef USE_POWER_PINS
    inout         vccd1,
    inout         vssd1,
`endif
    input         clk0,
    input         csb0,
    input         web0,
    input  [3:0]  wmask0,
    input  [8:0]  addr0,
    input  [31:0] din0,
    output [31:0] dout0,
    input         clk1,
    input         csb1,
    input  [8:0]  addr1,
    output [31:0] dout1
);
endmodule
