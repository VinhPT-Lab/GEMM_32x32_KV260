/// sta-blackbox
// Port-only view of the sky130 integrated clock gate that AxisClockGate
// instantiates by name (GEMM_AXIS_CG=1; dlclkp_4 with GEMM_ICG_X4). Same use as gemm_core/sram_bb.v:
// the Verilator lint and Yosys see the ports and keep the instance; STA skips
// this file and takes the cell from the std-cell liberty.
(* blackbox *)
module sky130_fd_sc_hd__dlclkp_1 (
`ifdef USE_POWER_PINS
    inout  VPWR,
    inout  VGND,
    inout  VPB,
    inout  VNB,
`endif
    input  CLK,
    input  GATE,
    output GCLK
);
endmodule

(* blackbox *)
module sky130_fd_sc_hd__dlclkp_4 (
`ifdef USE_POWER_PINS
    inout  VPWR,
    inout  VGND,
    inout  VPB,
    inout  VNB,
`endif
    input  CLK,
    input  GATE,
    output GCLK
);
endmodule
