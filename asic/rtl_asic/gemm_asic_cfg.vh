// ---------------------------------------------------------------------------
// gemm_asic_cfg.vh  -  one place to change the array size for the ASIC build.
//
// ProcessingElementRow is hardened as ONE macro and reused 32 times, so the
// row must not receive parameter overrides from its parent (a hard macro has
// no parameters). The row therefore takes its defaults from these defines,
// and ProcessingElementArray checks that its own parameters agree.
//
// Bring-up tip: set GEMM_N = 8, GEMM_RIW = 3 first and push that all the way
// to a clean GDS. Then go back to 32 / 5.
// ---------------------------------------------------------------------------
`ifndef GEMM_ASIC_CFG_VH
`define GEMM_ASIC_CFG_VH

`define GEMM_N    32   // array rows = array cols = stream lanes
`define GEMM_DW   8    // INT8 data width
`define GEMM_RIW  5    // log2(GEMM_N); psum width = 2*DW + RIW

// Async reset on pure datapath flops (PE feature/product/psum registers,
// FeatureSkew, OutputDeskew). 1 = same as the FPGA RTL. 0 = those flops have
// no reset: the array goes from ~92k resettable flops to ~16k (only the
// stationary-weight registers and control keep reset), smaller cells and a
// much lighter reset tree. Valid outputs are identical either way because
// every valid result is computed only from data that entered after reset;
// only the don't-care cycles differ (X in simulation). run_equiv.sh checks
// both settings. Can be overridden with +define+GEMM_DP_RESET=0 / SYNTH_DEFINES.
`ifndef GEMM_DP_RESET
`define GEMM_DP_RESET 1
`endif


// Buffer depths of the hardened GEMM core (words of 256/1024 bits). Chosen for
// sky130 OpenRAM 32x512 macros: weight 1024 (2 banks x 8 lanes), feature 512
// (8 lanes), output 512 (32 lanes). K up to 992 fits one N block; with K=896
// M <= 18 per job. Software limits must match (see GEMM_core.v header).
`ifndef GEMM_W_DEPTH
`define GEMM_W_DEPTH 1024
`endif
`ifndef GEMM_F_DEPTH
`define GEMM_F_DEPTH 512
`endif
`ifndef GEMM_O_DEPTH
`define GEMM_O_DEPTH 512
`endif

// AXI accelerator IP (rtl_asic/axi/GEMM_top.v): how the three AXI4-Stream
// ports are built. 0 = "thin", the KV260 adapters wire for wire (core port
// timing = IP port timing). 1 = "reg", a skid buffer on each stream so every
// AXIS port of the IP is registered. 2 = "lean", one-entry forward slices on
// the two inputs + a skid buffer on the result (input TREADY combinational,
// ~1/3 fewer flops). Override with +define+GEMM_AXIS_REG=n / SYNTH_DEFINES.
// Default: lean + clock gating (axi-shell 2026-10-10: 0.43 % of the core's
// std-cell area, about half the area of reg and less power than reg in every
// measurement: vectorless, VCD whole testbench, VCD compute window).
`ifndef GEMM_AXIS_REG
`define GEMM_AXIS_REG 2
`endif
// 1 = clock-gate the data banks of the stream slices (sky130 dlclkp ICG):
// banks that are not loading get no clock. Only with GEMM_AXIS_REG 1 or 2.
`ifndef GEMM_AXIS_CG
`define GEMM_AXIS_CG 1
`endif
// clock gates per data bank of a stream slice (AxisSkidBuffer/AxisFwdSlice
// P_CG_GROUPS): 1 = one gate per bank; gemm_ip_shell builds with 16.
`ifndef GEMM_CG_GROUPS
`define GEMM_CG_GROUPS 1
`endif

`endif
