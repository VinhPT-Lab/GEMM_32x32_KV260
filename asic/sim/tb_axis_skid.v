`timescale 1ns / 1ps
// ---------------------------------------------------------------------------
// tb_axis_skid - unit test of rtl_asic/axi/AxisSkidBuffer.v and AxisFwdSlice.v
//   -DTB_FWD : test AxisFwdSlice instead (its s_ready is combinational from
//              m_ready by design, so the "s_ready only changes on a clock
//              edge" check is off)
//   -DTB_CG  : with P_CLOCK_GATE = 1 (data banks behind AxisClockGate)
//   -DTB_CG_GROUPS=n : n clock gates per data bank (P_CG_GROUPS, default 1)
//
// The source sends the numbers 0, 1, 2, ... and the sink must see exactly
// that sequence: nothing lost, nothing repeated, nothing out of order. Four
// phases, each N_BEATS long:
//   1 random valid (50 %) / random ready (50 %)
//   2 valid and ready always high  -> must move one beat per cycle
//   3 heavy backpressure (ready 10 %), source always valid
//   4 bursty: ready and valid in long random runs
// AXI-Stream rules checked every cycle on both sides:
//   - while VALID && !READY, VALID stays high and DATA does not change
//   - s_ready low while in reset
//   - s_ready must come from a flop (checked indirectly: it may only change
//     right after a clock edge; the test drives inputs at negedge, so a
//     combinational path from s_valid/m_ready would show as a change there)
// Prints "SKID PASS" / "SKID FAIL".
//
// run: iverilog -g2012 [-DTB_FWD] [-DTB_CG] -o skid.vvp sim/tb_axis_skid.v rtl_asic/axi/AxisSkidBuffer.v \
//        rtl_asic/axi/AxisFwdSlice.v rtl_asic/axi/AxisClockGate.v && vvp -n skid.vvp
// ---------------------------------------------------------------------------
module tb_axis_skid;
localparam integer W       = 32;
localparam integer N_BEATS = 20000;

reg          clk = 1'b0;
reg          rst_n = 1'b0;
reg          s_valid = 1'b0;
reg  [W-1:0] s_data = {W{1'b0}};
wire         s_ready;
wire         m_valid;
wire [W-1:0] m_data;
reg          m_ready = 1'b0;

`ifdef TB_CG
localparam integer CG = 1;
`else
localparam integer CG = 0;
`endif
`ifndef TB_CG_GROUPS
`define TB_CG_GROUPS 1
`endif
localparam integer CGG = `TB_CG_GROUPS;     // clock gates per data bank
`ifdef TB_FWD
AxisFwdSlice #(.P_WIDTH(W), .P_CLOCK_GATE(CG), .P_CG_GROUPS(CGG)) dut (
`else
AxisSkidBuffer #(.P_WIDTH(W), .P_CLOCK_GATE(CG), .P_CG_GROUPS(CGG)) dut (
`endif
    .i_clk(clk), .i_rst_n(rst_n),
    .i_s_valid(s_valid), .o_s_ready(s_ready), .i_s_data(s_data),
    .o_m_valid(m_valid), .i_m_ready(m_ready), .o_m_data(m_data)
);

// the wide instance used in the IP, only to make sure it elaborates
wire w_wv, w_wr;
wire [257:0] w_wd;
`ifdef TB_FWD
AxisFwdSlice #(.P_WIDTH(258), .P_CLOCK_GATE(CG), .P_CG_GROUPS(CGG)) dut_wide (
`else
AxisSkidBuffer #(.P_WIDTH(258), .P_CLOCK_GATE(CG), .P_CG_GROUPS(CGG)) dut_wide (
`endif
    .i_clk(clk), .i_rst_n(rst_n),
    .i_s_valid(1'b0), .o_s_ready(w_wr), .i_s_data(258'd0),
    .o_m_valid(w_wv), .i_m_ready(1'b1), .o_m_data(w_wd)
);

always #5 clk = ~clk;

integer phase = 0;
integer sent = 0;          // beats accepted on the s side
integer got  = 0;          // beats accepted on the m side
integer errors = 0;
integer cycles = 0;
integer phase_start_cycle = 0;
integer phase_start_got = 0;
integer seed = 32'h5eed;
integer run_v = 0, run_r = 0;
reg     v_state = 1'b0, r_state = 1'b0;

reg          prev_m_stall = 1'b0;
reg  [W-1:0] prev_m_data;
reg          prev_s_ready;

task fail(input [8*64-1:0] what);
begin
    errors = errors + 1;
    if (errors <= 20)
        $display("ERROR cycle %0d phase %0d: %0s (m_data=%0d expected=%0d)", cycles, phase, what, m_data, got);
end
endtask

// ---- checks and counters on the clock edge
always @(posedge clk) begin
    if (rst_n) begin
        cycles <= cycles + 1;
        if (m_valid && m_ready) begin
            if (m_data !== got[W-1:0]) fail("wrong beat on the m side");
            got <= got + 1;
        end
        if (prev_m_stall) begin
            if (!m_valid)              fail("m_valid dropped while stalled");
            if (m_data !== prev_m_data) fail("m_data changed while stalled");
        end
        prev_m_stall <= m_valid && !m_ready;
        prev_m_data  <= m_data;
        if (s_valid && s_ready) sent <= sent + 1;
    end
end

// ---- s_ready must be low in reset (and in the first cycle after it, which
// the source sees as an ordinary stall)
always @(posedge clk)
    if (!rst_n && s_ready === 1'b1) fail("s_ready high during reset");

// ---- s_ready must not react to inputs between clock edges
always @(negedge clk) prev_s_ready <= s_ready;
`ifndef TB_FWD
always @(s_valid or m_ready or s_data) begin
    #1;
    if (rst_n && (s_ready !== prev_s_ready)) fail("s_ready changed without a clock edge");
end
`endif

// ---- stimulus: decided at negedge, from the state after the posedge
function rnd_pct(input integer pct);
    rnd_pct = (($random(seed) & 32'h7fffffff) % 100) < pct;
endfunction

always @(negedge clk) begin
    if (rst_n) begin
        // source: once VALID is up with a beat it stays up until accepted.
        // `sent` counts accepted beats (updated at the posedge), so the beat
        // on the bus is still waiting exactly when s_data == sent.
        if (s_valid && (s_data == sent[W-1:0])) begin
            // hold: same data, valid stays
        end
        else begin
            case (phase)
                1: s_valid <= rnd_pct(50);
                2: s_valid <= 1'b1;
                3: s_valid <= 1'b1;
                default: begin
                    if (run_v == 0) begin v_state = ~v_state; run_v = 1 + (($random(seed) & 32'h7fffffff) % 40); end
                    run_v = run_v - 1;
                    s_valid <= v_state;
                end
            endcase
            s_data <= sent[W-1:0];
        end
        case (phase)
            1: m_ready <= rnd_pct(50);
            2: m_ready <= 1'b1;
            3: m_ready <= rnd_pct(10);
            default: begin
                if (run_r == 0) begin r_state = ~r_state; run_r = 1 + (($random(seed) & 32'h7fffffff) % 40); end
                run_r = run_r - 1;
                m_ready <= r_state;
            end
        endcase
    end
end

integer p;
initial begin
    repeat (5) @(posedge clk);
    @(negedge clk) rst_n = 1'b1;
    for (p = 1; p <= 4; p = p + 1) begin
        phase = p;
        phase_start_cycle = cycles;
        phase_start_got = got;
        wait (got >= p * N_BEATS);
        if (p == 2) begin
            // one beat per cycle once the pipe is full (allow the fill)
            if ((cycles - phase_start_cycle) > N_BEATS + 4)
                fail("no full throughput with valid and ready always high");
            $display("phase 2: %0d beats in %0d cycles", got - phase_start_got, cycles - phase_start_cycle);
        end
        $display("phase %0d done at cycle %0d (sent %0d, received %0d)", p, cycles, sent, got);
    end
    // drain: stop sending, keep ready high, everything sent must come out
    phase = 5;
    @(negedge clk);
    force s_valid = 1'b0;
    force m_ready = 1'b1;
    repeat (10) @(posedge clk);
    if (got != sent) fail("beats left inside after draining");
    $display("sent %0d, received %0d, errors %0d", sent, got, errors);
`ifdef TB_FWD
    $display("dut: AxisFwdSlice, P_CLOCK_GATE=%0d, P_CG_GROUPS=%0d", CG, CGG);
`else
    $display("dut: AxisSkidBuffer, P_CLOCK_GATE=%0d, P_CG_GROUPS=%0d", CG, CGG);
`endif
    $display("%s", errors == 0 ? "SKID PASS" : "SKID FAIL");
    $finish;
end

initial begin
    #(10 * 6 * N_BEATS * 20);
    $display("timeout");
    $display("SKID FAIL");
    $finish;
end

endmodule
