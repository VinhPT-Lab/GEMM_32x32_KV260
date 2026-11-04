`timescale 1ns / 1ps
// ---------------------------------------------------------------------------
// AxisSkidBuffer - two-entry register slice for one valid/ready stream.
//
// Every output of this block comes straight from a flop: m_valid, m_data and
// s_ready. Nothing combinational runs from the s_ side to the m_ side or
// back, so a stream port behind one of these has no in->out feedthrough and
// its timing does not depend on whoever drives or receives it.
//
//   main entry  (r_m_valid, r_m_data)   : what the m_ side sees
//   skid entry  (r_s_valid, r_s_data)   : catches the one beat that arrives
//                                         in the cycle the m_ side stalls,
//                                         because s_ready is a cycle late
//
// Full throughput (one beat per cycle) while m_ready stays high; after a
// stall the beat in the skid entry goes out first, so order is kept and no
// beat is lost or repeated.
//
// s_ready stays low during reset and for the first cycle after it (r_ready):
// the parent resets this block from a synchronised reset that releases a few
// cycles after the port reset, and a beat offered in that gap must not be
// taken and lost.
//
// The data flops have no reset (only the valid/ready flops do): they are
// loaded before they are used, and leaving the reset off saves area and the
// reset fanout on P_WIDTH bits. They only load when a beat is taken, which
// also keeps their toggling (power) down to the real traffic.
//
// P_CLOCK_GATE = 1: each data bank (main, skid) gets its clock through an
// AxisClockGate whose enable is exactly that bank's load condition, so the
// banks see no clock edge at all in the cycles they hold their value. Same
// behaviour cycle for cycle; only the clock power of ~2 x P_WIDTH flops goes.
// P_CG_GROUPS > 1 splits each bank into that many runs of adjacent bits, each
// behind its own AxisClockGate (same enable as the bank), so each gate drives
// a short clock net.
// ---------------------------------------------------------------------------
module AxisSkidBuffer
#(
    parameter integer P_WIDTH      = 258,
    parameter integer P_CLOCK_GATE = 0,
    parameter integer P_CG_GROUPS  = 1
)
(
    input                   i_clk,
    input                   i_rst_n,

    input                   i_s_valid,
    output                  o_s_ready,
    input  [P_WIDTH-1:0]    i_s_data,

    output                  o_m_valid,
    input                   i_m_ready,
    output [P_WIDTH-1:0]    o_m_data
);

reg                 r_m_valid;
reg [P_WIDTH-1:0]   r_m_data;
reg                 r_s_valid;      // skid entry full
reg [P_WIDTH-1:0]   r_s_data;
reg                 r_ready;        // 0 in reset, 1 from the first cycle after it

wire w_s_ready  = ~r_s_valid & r_ready;
wire w_m_free   = i_m_ready | ~r_m_valid;   // main entry empty or leaving this cycle
wire w_s_accept = i_s_valid & w_s_ready;

always @(posedge i_clk or negedge i_rst_n) begin
    if (~i_rst_n) begin
        r_m_valid <= 1'b0;
        r_s_valid <= 1'b0;
        r_ready   <= 1'b0;
    end
    else begin
        r_ready <= 1'b1;
        if (w_m_free) begin
            if (r_s_valid) begin
                r_m_valid <= 1'b1;          // skid beat moves to main
                r_s_valid <= 1'b0;
            end
            else
                r_m_valid <= w_s_accept;    // new beat straight into main
        end
        else if (w_s_accept)
            r_s_valid <= 1'b1;              // main is stalled: park the new beat
    end
end

// load conditions of the two data banks
wire w_load_m = w_m_free & (r_s_valid | w_s_accept);    // main takes the skid beat or the new one
wire w_load_s = ~w_m_free & w_s_accept;                 // skid parks the new beat

generate
if (P_CLOCK_GATE != 0 && P_CG_GROUPS > 1) begin : g_cgn
    wire [P_WIDTH-1:0] w_m_data, w_s_data;
    genvar g;
    for (g = 0; g < P_CG_GROUPS; g = g + 1) begin : g_grp
        localparam integer LO = g * P_WIDTH / P_CG_GROUPS;
        localparam integer HI = (g + 1) * P_WIDTH / P_CG_GROUPS;    // exclusive
        wire            w_gclk_m, w_gclk_s;
        reg [HI-LO-1:0] r_m_part, r_s_part;
        AxisClockGate u_cg_m (.i_clk(i_clk), .i_en(w_load_m), .o_gclk(w_gclk_m));
        AxisClockGate u_cg_s (.i_clk(i_clk), .i_en(w_load_s), .o_gclk(w_gclk_s));
        always @(posedge w_gclk_m)
            r_m_part <= r_s_valid ? r_s_part : i_s_data[HI-1:LO];
        always @(posedge w_gclk_s)
            r_s_part <= i_s_data[HI-1:LO];
        assign w_m_data[HI-1:LO] = r_m_part;
        assign w_s_data[HI-1:LO] = r_s_part;
    end
    always @(*) begin
        r_m_data = w_m_data;
        r_s_data = w_s_data;
    end
end
else if (P_CLOCK_GATE != 0) begin : g_cg
    wire w_gclk_m, w_gclk_s;
    AxisClockGate u_cg_m (.i_clk(i_clk), .i_en(w_load_m), .o_gclk(w_gclk_m));
    AxisClockGate u_cg_s (.i_clk(i_clk), .i_en(w_load_s), .o_gclk(w_gclk_s));
    always @(posedge w_gclk_m)
        r_m_data <= r_s_valid ? r_s_data : i_s_data;
    always @(posedge w_gclk_s)
        r_s_data <= i_s_data;
end
else begin : g_en
    always @(posedge i_clk) begin
        if (w_load_m)
            r_m_data <= r_s_valid ? r_s_data : i_s_data;
        if (w_load_s)
            r_s_data <= i_s_data;
    end
end
endgenerate

assign o_s_ready = w_s_ready;
assign o_m_valid = r_m_valid;
assign o_m_data  = r_m_data;

endmodule
