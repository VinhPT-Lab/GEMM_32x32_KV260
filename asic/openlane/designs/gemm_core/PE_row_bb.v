/// sta-blackbox
// ---------------------------------------------------------------------------
// Port-only view of ProcessingElementRow (GEMM_N=32, DW=8, RIW=5) for the
// level ABOVE the row macro (OpenLane VERILOG_FILES_BLACKBOX). The real row is
// the hardened macro; its timing comes from the row run's .lib (EXTRA_LIBS).
// Line 1 tells OpenLane's STA to skip this file instead of parsing it as a
// gate-level netlist. Ports must match rtl_asic/PE_row.v exactly.
// ---------------------------------------------------------------------------
(* blackbox *)
module ProcessingElementRow (
`ifdef USE_POWER_PINS
    inout          vccd1,
    inout          vssd1,
`endif
    input          i_clk,
    input          i_rst_n,
    input          i_weight_shift_en,
    input          i_weight_load,
    input  [255:0] i_weight_shift_in,      // 32 x 8
    output [255:0] o_weight_shift_out,
    input  [7:0]   i_feature_value,
    input  [671:0] i_partial_sum_vector,   // 32 x 21
    output [671:0] o_partial_sum_vector
);
endmodule
