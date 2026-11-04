# ---------------------------------------------------------------------------
# Measurement run - the AXI shell of the accelerator IP alone:
#   GemmAxiShell (rtl_asic/axi): ResetSync + AXI4-Lite register file + job
#   status + the three AXI4-Stream ports, without the GEMM core.
# What it gives: the cell area, flop count, timing and power the AXI
# interface adds to core_v11, for each stream variant:
#   openlane/run_flow.sh axi-shell      tags shell_thin, shell_reg, shell_lean, shell_lean_cg
#                                       (AXI_SHELL_VARIANTS), each after a shell_<v>_cal run
# The die (sizes.tcl, pin_order.cfg from gen_axi_files.py) is sized by the
# ~1780 ports, not by the logic, so DIEAREA / utilisation of this run mean
# nothing; read the cell area.
# ---------------------------------------------------------------------------
source $::env(DESIGN_DIR)/../gemm_common.tcl
source $::env(DESIGN_DIR)/sizes.tcl

# GEMM_AXIS_REG: 0 = thin (KV260 adapters), 1 = reg (skid buffers),
# 2 = lean (forward slices in, skid buffer out); GEMM_AXIS_CG: 1 = clock-gated
# slice data banks (sky130 dlclkp). run_flow.sh writes variant.tcl before each
# run; lean with clock gating (the IP default, gemm_asic_cfg.vh) if it is missing.
set ::env(GEMM_AXIS_REG) 2
set ::env(GEMM_AXIS_CG)  1
if { [file exists $::env(DESIGN_DIR)/variant.tcl] } { source $::env(DESIGN_DIR)/variant.tcl }

set ::env(DESIGN_NAME) "GemmAxiShell"
set SRC $::env(DESIGN_DIR)/src
set ::env(VERILOG_FILES) [list $SRC/GemmAxiShell.v $SRC/AxiLiteControlRegs.v \
                              $SRC/AxisSkidBuffer.v $SRC/AxisFwdSlice.v $SRC/AxisClockGate.v \
                              $SRC/ResetSync.v]
set ::env(VERILOG_INCLUDE_DIRS) [list $SRC]
set ::env(SYNTH_DEFINES) [list GEMM_AXIS_REG=$::env(GEMM_AXIS_REG) GEMM_AXIS_CG=$::env(GEMM_AXIS_CG)]
# AxisClockGate instantiates sky130_fd_sc_hd__dlclkp_1 by name. Yosys only gets
# std cells for mapping (SYNTH_READ_BLACKBOX_LIB is 0), so without this port
# view it stops at "hierarchy -check"; the Verilator lint needs it too in case
# SYNTHESIS is defined there.
if { $::env(GEMM_AXIS_CG) } { set ::env(VERILOG_FILES_BLACKBOX) [list $::env(DESIGN_DIR)/dlclkp_bb.v] }

set ::env(CLOCK_PORT) "S_AXI_ACLK"
set ::env(CLOCK_NET)  "S_AXI_ACLK"
# CLOCK_PERIOD 10 from gemm_common.tcl (100 MHz, same as the core)

# Port budget: logic outside the shell may use this fraction of the period on
# each side (AXI master / interconnect on the West edge, core logic on the
# East edge). 0.3 = 3 ns of a 10 ns cycle. In "thin" the AXIS ports are wires
# through the shell, so a feedthrough (in -> out) has 10 - 2 x 3 = 4 ns.
set ::env(GEMM_SHELL_IO_PCT) 0.3
set ::env(BASE_SDC_FILE) $::env(DESIGN_DIR)/shell.sdc
# outside clock latency for shell.sdc: 0 unless run_flow.sh measured the
# shell's own latency in a calibration run (clk_latency.tcl)
if { [file exists $::env(DESIGN_DIR)/clk_latency.tcl] } { source $::env(DESIGN_DIR)/clk_latency.tcl }

# built like a macro, as it would sit next to the core
set ::env(DESIGN_IS_CORE)   0
set ::env(FP_PDN_CORE_RING) 0
set ::env(RT_MAX_LAYER)     "met4"
set ::env(FP_PIN_ORDER_CFG) $::env(DESIGN_DIR)/pin_order.cfg
# spread the cells: at 0.50 (first runs) the skid buffers of "reg" sat in a
# dense band against the West pins and global routing overflowed there
set ::env(PL_TARGET_DENSITY) 0.30
# small leftover overflow goes to detailed routing (as in gemm_core), which
# reports real shorts if it cannot fix it - QUIT_ON_TR_DRC stays on
set ::env(GRT_ALLOW_CONGESTION) 1

# antenna: the AXIS ports of "thin" are ~600 um wires straight across the
# die, and every input port drives gates through such a wire (first thin run:
# 305 pins). Diodes on the input ports + the heuristic diodes (fine here:
# no congestion problem on a 17 %-used die) + more repair rounds in the
# global route. DIODE_ON_PORTS needs RUN_HEURISTIC_DIODE_INSERTION.
set ::env(RUN_HEURISTIC_DIODE_INSERTION) 1
set ::env(DIODE_ON_PORTS)                "in"
set ::env(GRT_REPAIR_ANTENNAS)           1
set ::env(GRT_ANT_ITERS)                 10

# finish the run and report, a timing miss is a result here
set ::env(QUIT_ON_TIMING_VIOLATIONS) 0
set ::env(QUIT_ON_SETUP_VIOLATIONS)  0
set ::env(QUIT_ON_HOLD_VIOLATIONS)   0
