`timescale 1ns / 1ps
`include "gemm_asic_cfg.vh"
// ---------------------------------------------------------------------------
// GemmAxiShell - everything of the AXI accelerator IP except the GEMM core:
//   ResetSync, the AXI4-Lite register file, the job status flags and the
//   three AXI4-Stream ports (feature in, weight in, result out).
//
// GEMM_top = GemmAxiShell + GemmAccelerator. The shell is its own module so
// it can be hardened and measured alone (openlane/designs/gemm_axi_shell):
// that is the area/timing/power the AXI interface adds to core_v11.
//
// P_AXIS_REG selects how the stream ports are built:
//   0 "thin": exactly the KV260 IP (axi_ip/*_full_beat_slave, result
//     adapter). TDATA/TVALID/TLAST go straight to the core, TREADY comes
//     straight from the core (and from TSTRB on the inputs), so the core's
//     port timing is the IP's port timing and TSTRB -> TREADY is a
//     combinational in->out path.
//   1 "reg": an AxisSkidBuffer on each stream. Every AXIS output of the IP
//     is a flop and every AXIS input goes into a flop, so the IP can sit in
//     an SoC at full clock without any I/O timing waiver. Costs ~2 x 258
//     flops per stream and one cycle of latency per stream; throughput
//     stays at one beat per cycle.
//   2 "lean": AxisFwdSlice (one entry) on feature and weight, AxisSkidBuffer
//     on result. TDATA/TVALID inputs still land in flops and every result
//     output is a flop; only the two input TREADYs are combinational (one
//     AND-OR from the core's ready, itself a counter compare on flops).
//     ~1/3 fewer flops than "reg".
// P_AXIS_CG = 1 clock-gates the data banks of the slices (AxisClockGate,
// sky130 dlclkp): no clock on 258-bit banks that are not loading. No effect
// with P_AXIS_REG = 0 (no slices).
//
// Partial beats (TSTRB not all ones; the KV260 driver never sends them):
// no variant hands one to the core, and the stream stops there until reset,
// as on the KV260. The difference: in "thin" TREADY stays low, so the master
// still holds the beat (KV260 behaviour); in "reg" and "lean" the full-beat
// flag travels with the beat and TREADY no longer depends on TSTRB, so the
// slice has already accepted the partial beat (in "reg" also the next one)
// when it stops. Either way the job never finishes; only a reset recovers.
// ERROR[0]/[1] and IRQ_STATUS[1] are set once per partial beat offered (first
// cycle only), so a beat the master keeps holding in "thin" does not set them
// again every cycle and a W1C clear sticks.
//
// The job status flags (busy/done for register 0x00) are taken from the
// handshakes on the IP ports, not on the core side: in "reg" the last
// result beat is still in the output slice when the core lets go of it,
// and done must mean the result has left the IP. In "thin" both sides are
// the same wires, so the flags behave exactly as on the KV260.
//
// Also here, for the registers past 0x0C (AxiLiteControlRegs): the job cycle
// counter (first accepted input beat .. last result beat; meant for jobs that
// do not overlap, as the KV260 driver runs them), the partial-beat error
// pulses, the job-done event and the interrupt output o_irq.
// ---------------------------------------------------------------------------
module GemmAxiShell
#(
    parameter integer P_AXI_LITE_DATA_WIDTH = 32,
    parameter integer P_AXI_LITE_ADDR_WIDTH = 6,
    parameter integer P_STREAM_WIDTH        = 256,      // 32 lanes x 8 bit, as the core
    parameter integer P_AXIS_REG            = `GEMM_AXIS_REG,
    parameter integer P_AXIS_CG             = `GEMM_AXIS_CG,
    parameter integer P_CG_GROUPS           = `GEMM_CG_GROUPS     // clock gates per data bank
)
(
    // ---- AXI4-Lite control (clock and reset of the whole IP)
    input                                   S_AXI_ACLK,
    input                                   S_AXI_ARESETN,
    input  [P_AXI_LITE_ADDR_WIDTH-1:0]      S_AXI_AWADDR,
    input  [2:0]                            S_AXI_AWPROT,
    input                                   S_AXI_AWVALID,
    output                                  S_AXI_AWREADY,
    input  [P_AXI_LITE_DATA_WIDTH-1:0]      S_AXI_WDATA,
    input  [(P_AXI_LITE_DATA_WIDTH/8)-1:0]  S_AXI_WSTRB,
    input                                   S_AXI_WVALID,
    output                                  S_AXI_WREADY,
    output [1:0]                            S_AXI_BRESP,
    output                                  S_AXI_BVALID,
    input                                   S_AXI_BREADY,
    input  [P_AXI_LITE_ADDR_WIDTH-1:0]      S_AXI_ARADDR,
    input  [2:0]                            S_AXI_ARPROT,
    input                                   S_AXI_ARVALID,
    output                                  S_AXI_ARREADY,
    output [P_AXI_LITE_DATA_WIDTH-1:0]      S_AXI_RDATA,
    output [1:0]                            S_AXI_RRESP,
    output                                  S_AXI_RVALID,
    input                                   S_AXI_RREADY,
    output                                  irq,            // job done / error, level, active high

    // ---- feature AXI4-Stream slave
    output                                  feature_axis_tready,
    input  [P_STREAM_WIDTH-1:0]             feature_axis_tdata,
    input  [(P_STREAM_WIDTH/8)-1:0]         feature_axis_tstrb,
    input                                   feature_axis_tlast,
    input                                   feature_axis_tvalid,

    // ---- weight AXI4-Stream slave
    output                                  weight_axis_tready,
    input  [P_STREAM_WIDTH-1:0]             weight_axis_tdata,
    input  [(P_STREAM_WIDTH/8)-1:0]         weight_axis_tstrb,
    input                                   weight_axis_tlast,
    input                                   weight_axis_tvalid,

    // ---- result AXI4-Stream master
    output                                  result_axis_tvalid,
    output [P_STREAM_WIDTH-1:0]             result_axis_tdata,
    output [(P_STREAM_WIDTH/8)-1:0]         result_axis_tstrb,
    output                                  result_axis_tlast,
    input                                   result_axis_tready,

    // ---- to / from GemmAccelerator (same clock: S_AXI_ACLK)
    output                                  o_core_rst_n,
    output [9:0]                            o_cfg_shift,
    output [8:0]                            o_cfg_row_count,
    output [4:0]                            o_cfg_k_block_count,
    output [4:0]                            o_cfg_n_block_count,

    output                                  o_feature_valid,
    output                                  o_feature_last,
    input                                   i_feature_ready,
    output [P_STREAM_WIDTH-1:0]             o_feature_data,

    output                                  o_weight_valid,
    output                                  o_weight_last,
    input                                   i_weight_ready,
    output [P_STREAM_WIDTH-1:0]             o_weight_data,

    input                                   i_result_valid,
    output                                  o_result_ready,
    input                                   i_result_last,
    input  [P_STREAM_WIDTH-1:0]             i_result_data
);

localparam integer LP_STRB = P_STREAM_WIDTH / 8;
// IP_VERSION (0x24): 1.1, [15:8] array size = lanes per stream beat, [7:0] 8-bit data
// (32-bit arithmetic all the way, so the lint sees no truncation)
localparam [31:0] LP_VERSION = 32'h0101_0008 | ((P_STREAM_WIDTH / 8) << 8);

// ---------------------------------------------------------------------------
// reset: asynchronous assert, synchronous release (on the KV260 the
// proc_sys_reset IP did this). One reset for the shell and the core.
// ---------------------------------------------------------------------------
wire w_rst_n;
ResetSync #(.P_STAGES(2)) u_reset_sync (
    .i_clk          (S_AXI_ACLK),
    .i_rst_n_async  (S_AXI_ARESETN),
    .o_rst_n_sync   (w_rst_n)
);
assign o_core_rst_n = w_rst_n;

// ---------------------------------------------------------------------------
// AXI4-Lite registers + job status (GEMM_top.v of the KV260, unchanged
// except that the handshakes are the port-side ones, see the header)
// ---------------------------------------------------------------------------
reg  r_job_busy;
reg  r_job_done;
reg  r_job_clear_accepted;
reg  r_job_clear_busy_error;
reg  [31:0] r_job_cycles;
wire w_job_start_clear;

wire w_feature_full    = &feature_axis_tstrb;
wire w_weight_full     = &weight_axis_tstrb;
// a beat offered with TSTRB not all ones (sticky error bit in register 0x18):
// one pulse on the first cycle it is offered, not one per cycle it is held
wire w_feature_partial = feature_axis_tvalid & ~w_feature_full;
wire w_weight_partial  = weight_axis_tvalid  & ~w_weight_full;
reg  [1:0] r_partial_q;
always @(posedge S_AXI_ACLK or negedge w_rst_n) begin
    if (~w_rst_n) r_partial_q <= 2'b00;
    else          r_partial_q <= {w_weight_partial, w_feature_partial};
end
wire [1:0] w_partial_event = {w_weight_partial, w_feature_partial} & ~r_partial_q;

wire w_feature_accept = feature_axis_tvalid & feature_axis_tready;
wire w_weight_accept  = weight_axis_tvalid  & weight_axis_tready;
wire w_final_accept   = result_axis_tvalid  & result_axis_tready & result_axis_tlast;
wire w_job_activity   = w_feature_accept | w_weight_accept | result_axis_tvalid;

AxiLiteControlRegs #(
    .P_AXI_LITE_DATA_WIDTH(P_AXI_LITE_DATA_WIDTH),
    .P_AXI_LITE_ADDR_WIDTH(P_AXI_LITE_ADDR_WIDTH),
    .P_IP_VERSION         (LP_VERSION)
) u_control_registers (
    .o_cfg_shift            (o_cfg_shift),
    .o_cfg_row_count        (o_cfg_row_count),
    .o_cfg_k_block_count    (o_cfg_k_block_count),
    .o_cfg_n_block_count    (o_cfg_n_block_count),
    .o_job_start_clear      (w_job_start_clear),
    .i_job_busy             (r_job_busy),
    .i_job_done             (r_job_done),
    .i_job_idle             (~r_job_busy),
    .i_job_clear_accepted   (r_job_clear_accepted),
    .i_job_clear_busy_error (r_job_clear_busy_error),
    .i_job_done_event       (w_final_accept),
    .i_partial_beat         (w_partial_event),
    .i_job_cycles           (r_job_cycles),
    .o_irq                  (irq),

    .S_AXI_ACLK    (S_AXI_ACLK),
    .S_AXI_ARESETN (w_rst_n),
    .S_AXI_AWADDR  (S_AXI_AWADDR),
    .S_AXI_AWPROT  (S_AXI_AWPROT),
    .S_AXI_AWVALID (S_AXI_AWVALID),
    .S_AXI_AWREADY (S_AXI_AWREADY),
    .S_AXI_WDATA   (S_AXI_WDATA),
    .S_AXI_WSTRB   (S_AXI_WSTRB),
    .S_AXI_WVALID  (S_AXI_WVALID),
    .S_AXI_WREADY  (S_AXI_WREADY),
    .S_AXI_BRESP   (S_AXI_BRESP),
    .S_AXI_BVALID  (S_AXI_BVALID),
    .S_AXI_BREADY  (S_AXI_BREADY),
    .S_AXI_ARADDR  (S_AXI_ARADDR),
    .S_AXI_ARPROT  (S_AXI_ARPROT),
    .S_AXI_ARVALID (S_AXI_ARVALID),
    .S_AXI_ARREADY (S_AXI_ARREADY),
    .S_AXI_RDATA   (S_AXI_RDATA),
    .S_AXI_RRESP   (S_AXI_RRESP),
    .S_AXI_RVALID  (S_AXI_RVALID),
    .S_AXI_RREADY  (S_AXI_RREADY)
);

always @(posedge S_AXI_ACLK or negedge w_rst_n) begin
    if (~w_rst_n) begin
        r_job_busy             <= 1'b0;
        r_job_done             <= 1'b0;
        r_job_clear_accepted   <= 1'b0;
        r_job_clear_busy_error <= 1'b0;
    end
    else begin
        r_job_clear_accepted   <= 1'b0;
        r_job_clear_busy_error <= 1'b0;

        if (w_job_start_clear) begin
            if (r_job_busy)
                r_job_clear_busy_error <= 1'b1;
            else begin
                r_job_done           <= 1'b0;
                r_job_clear_accepted <= 1'b1;
            end
        end

        if (w_final_accept) begin
            r_job_busy <= 1'b0;
            r_job_done <= 1'b1;
        end
        else if (w_job_activity) begin
            r_job_busy <= 1'b1;
            r_job_done <= 1'b0;
        end
    end
end

// job cycle counter (register 0x1C): restarts at the first activity after an
// idle period, counts every cycle while busy (the last-beat cycle included),
// then holds; saturates instead of wrapping. Meant for jobs that do not
// overlap (the KV260 driver waits for done): input beats of the next job
// taken before this job's last result beat are not in the next job's count.
always @(posedge S_AXI_ACLK or negedge w_rst_n) begin
    if (~w_rst_n)
        r_job_cycles <= 32'd0;
    else if (~r_job_busy & w_job_activity)
        r_job_cycles <= 32'd1;
    else if (r_job_busy & ~&r_job_cycles)
        r_job_cycles <= r_job_cycles + 32'd1;
end

// result TSTRB: always full beats, as on the KV260
assign result_axis_tstrb = {LP_STRB{1'b1}};

generate
if (P_AXIS_REG == 0) begin : g_thin
    // ---- KV260 adapters, wire for wire
    assign o_feature_data      = feature_axis_tdata;
    assign o_feature_valid     = feature_axis_tvalid & w_feature_full;
    assign o_feature_last      = feature_axis_tlast  & w_feature_full;
    assign feature_axis_tready = i_feature_ready     & w_feature_full;

    assign o_weight_data       = weight_axis_tdata;
    assign o_weight_valid      = weight_axis_tvalid & w_weight_full;
    assign o_weight_last       = weight_axis_tlast  & w_weight_full;
    assign weight_axis_tready  = i_weight_ready     & w_weight_full;

    assign result_axis_tdata   = i_result_data;
    assign result_axis_tvalid  = i_result_valid;
    assign result_axis_tlast   = i_result_last;
    assign o_result_ready      = result_axis_tready;
end
else if (P_AXIS_REG == 1) begin : g_reg
    // ---- feature: {full, last, data} through a skid buffer
    wire                      w_f_valid;
    wire [P_STREAM_WIDTH+1:0] w_f_beat;
    AxisSkidBuffer #(.P_WIDTH(P_STREAM_WIDTH + 2), .P_CLOCK_GATE(P_AXIS_CG), .P_CG_GROUPS(P_CG_GROUPS)) u_feature_slice (
        .i_clk     (S_AXI_ACLK),
        .i_rst_n   (w_rst_n),
        .i_s_valid (feature_axis_tvalid),
        .o_s_ready (feature_axis_tready),
        .i_s_data  ({w_feature_full, feature_axis_tlast, feature_axis_tdata}),
        .o_m_valid (w_f_valid),
        .i_m_ready (i_feature_ready & w_f_beat[P_STREAM_WIDTH+1]),
        .o_m_data  (w_f_beat)
    );
    assign o_feature_data  = w_f_beat[P_STREAM_WIDTH-1:0];
    assign o_feature_last  = w_f_beat[P_STREAM_WIDTH];
    assign o_feature_valid = w_f_valid & w_f_beat[P_STREAM_WIDTH+1];

    // ---- weight: same
    wire                      w_w_valid;
    wire [P_STREAM_WIDTH+1:0] w_w_beat;
    AxisSkidBuffer #(.P_WIDTH(P_STREAM_WIDTH + 2), .P_CLOCK_GATE(P_AXIS_CG), .P_CG_GROUPS(P_CG_GROUPS)) u_weight_slice (
        .i_clk     (S_AXI_ACLK),
        .i_rst_n   (w_rst_n),
        .i_s_valid (weight_axis_tvalid),
        .o_s_ready (weight_axis_tready),
        .i_s_data  ({w_weight_full, weight_axis_tlast, weight_axis_tdata}),
        .o_m_valid (w_w_valid),
        .i_m_ready (i_weight_ready & w_w_beat[P_STREAM_WIDTH+1]),
        .o_m_data  (w_w_beat)
    );
    assign o_weight_data  = w_w_beat[P_STREAM_WIDTH-1:0];
    assign o_weight_last  = w_w_beat[P_STREAM_WIDTH];
    assign o_weight_valid = w_w_valid & w_w_beat[P_STREAM_WIDTH+1];

    // ---- result: {last, data} through a skid buffer
    wire [P_STREAM_WIDTH:0] w_r_beat;
    AxisSkidBuffer #(.P_WIDTH(P_STREAM_WIDTH + 1), .P_CLOCK_GATE(P_AXIS_CG), .P_CG_GROUPS(P_CG_GROUPS)) u_result_slice (
        .i_clk     (S_AXI_ACLK),
        .i_rst_n   (w_rst_n),
        .i_s_valid (i_result_valid),
        .o_s_ready (o_result_ready),
        .i_s_data  ({i_result_last, i_result_data}),
        .o_m_valid (result_axis_tvalid),
        .i_m_ready (result_axis_tready),
        .o_m_data  (w_r_beat)
    );
    assign result_axis_tdata = w_r_beat[P_STREAM_WIDTH-1:0];
    assign result_axis_tlast = w_r_beat[P_STREAM_WIDTH];
end
else begin : g_lean
    // ---- feature / weight: one-entry forward slices, {full, last, data}
    wire                      w_f_valid;
    wire [P_STREAM_WIDTH+1:0] w_f_beat;
    AxisFwdSlice #(.P_WIDTH(P_STREAM_WIDTH + 2), .P_CLOCK_GATE(P_AXIS_CG), .P_CG_GROUPS(P_CG_GROUPS)) u_feature_slice (
        .i_clk     (S_AXI_ACLK),
        .i_rst_n   (w_rst_n),
        .i_s_valid (feature_axis_tvalid),
        .o_s_ready (feature_axis_tready),
        .i_s_data  ({w_feature_full, feature_axis_tlast, feature_axis_tdata}),
        .o_m_valid (w_f_valid),
        .i_m_ready (i_feature_ready & w_f_beat[P_STREAM_WIDTH+1]),
        .o_m_data  (w_f_beat)
    );
    assign o_feature_data  = w_f_beat[P_STREAM_WIDTH-1:0];
    assign o_feature_last  = w_f_beat[P_STREAM_WIDTH];
    assign o_feature_valid = w_f_valid & w_f_beat[P_STREAM_WIDTH+1];

    wire                      w_w_valid;
    wire [P_STREAM_WIDTH+1:0] w_w_beat;
    AxisFwdSlice #(.P_WIDTH(P_STREAM_WIDTH + 2), .P_CLOCK_GATE(P_AXIS_CG), .P_CG_GROUPS(P_CG_GROUPS)) u_weight_slice (
        .i_clk     (S_AXI_ACLK),
        .i_rst_n   (w_rst_n),
        .i_s_valid (weight_axis_tvalid),
        .o_s_ready (weight_axis_tready),
        .i_s_data  ({w_weight_full, weight_axis_tlast, weight_axis_tdata}),
        .o_m_valid (w_w_valid),
        .i_m_ready (i_weight_ready & w_w_beat[P_STREAM_WIDTH+1]),
        .o_m_data  (w_w_beat)
    );
    assign o_weight_data  = w_w_beat[P_STREAM_WIDTH-1:0];
    assign o_weight_last  = w_w_beat[P_STREAM_WIDTH];
    assign o_weight_valid = w_w_valid & w_w_beat[P_STREAM_WIDTH+1];

    // ---- result: full skid buffer (its data comes through the core's shifter)
    wire [P_STREAM_WIDTH:0] w_r_beat;
    AxisSkidBuffer #(.P_WIDTH(P_STREAM_WIDTH + 1), .P_CLOCK_GATE(P_AXIS_CG), .P_CG_GROUPS(P_CG_GROUPS)) u_result_slice (
        .i_clk     (S_AXI_ACLK),
        .i_rst_n   (w_rst_n),
        .i_s_valid (i_result_valid),
        .o_s_ready (o_result_ready),
        .i_s_data  ({i_result_last, i_result_data}),
        .o_m_valid (result_axis_tvalid),
        .i_m_ready (result_axis_tready),
        .o_m_data  (w_r_beat)
    );
    assign result_axis_tdata = w_r_beat[P_STREAM_WIDTH-1:0];
    assign result_axis_tlast = w_r_beat[P_STREAM_WIDTH];
end
endgenerate

endmodule
