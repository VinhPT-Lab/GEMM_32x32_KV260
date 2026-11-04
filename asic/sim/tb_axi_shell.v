`timescale 1ns / 1ps
// ---------------------------------------------------------------------------
// tb_axi_shell - GemmAxiShell (rtl_asic/axi) on its own, against a small model
// of the core. Build with -DGEMM_AXIS_REG=0|1|2 -DGEMM_AXIS_CG=0|1.
//
// Checks, in order:
//   1 registers 0x00..0x0C read back what was written (used bits only),
//     IP_ID / IP_VERSION, unused offsets read 0
//   2 job 1: NF feature + NW weight beats in, NR result beats out, random
//     gaps on the AXIS masters, random ready on the result port, random ready
//     and valid on the core model. The core model checks every beat it gets
//     (value, order, TLAST); the testbench checks every result beat at the
//     port (value, order, TLAST) and the AXI-Stream rule that TVALID/TDATA/
//     TLAST hold while stalled
//   3 busy during the job, done after it; IRQ_STATUS[0] set; irq stays low
//     while IRQ_ENABLE = 0 and goes high once IRQ_ENABLE[0] is written;
//     write-1-to-clear drops it; JOB_CYCLES = cycles from the first accepted
//     input beat to the last result beat
//   4 job 2 with a clear-done write while busy: ERROR[2] set (sticky), job
//     still completes; W1C clears ERROR
//   5 a feature beat with TSTRB not all ones, held by the master: never
//     reaches the core, ERROR[0] and IRQ_STATUS[1] set, irq high with
//     IRQ_ENABLE[1]; cleared while the beat is still held, they stay clear
//     (one event per beat); then the same for a weight beat and ERROR[1]
// Prints "SHELL PASS" / "SHELL FAIL".
// ---------------------------------------------------------------------------
`include "gemm_asic_cfg.vh"
module tb_axi_shell;
localparam integer W  = 256;
localparam integer NF = 40;
localparam integer NW = 70;
localparam integer NR = 50;
localparam integer AW = 6;

reg clk = 1'b0;
reg rst_n = 1'b0;
always #5 clk = ~clk;
integer cycle = 0;
always @(posedge clk) cycle <= cycle + 1;
integer seed = 32'h1234;
integer errors = 0;

// ---- AXI4-Lite
reg  [AW-1:0] awaddr = 0;  reg awvalid = 0; wire awready;
reg  [31:0]   wdata = 0;   reg [3:0] wstrb = 0; reg wvalid = 0; wire wready;
wire [1:0]    bresp;       wire bvalid; reg bready = 0;
reg  [AW-1:0] araddr = 0;  reg arvalid = 0; wire arready;
wire [31:0]   rdata;       wire [1:0] rresp; wire rvalid; reg rready = 0;
wire          irq;
// ---- AXIS ports
reg  [W-1:0]  f_tdata = 0; reg [31:0] f_tstrb = {32{1'b1}}; reg f_tlast = 0, f_tvalid = 0; wire f_tready;
reg  [W-1:0]  w_tdata = 0; reg [31:0] w_tstrb = {32{1'b1}}; reg w_tlast = 0, w_tvalid = 0; wire w_tready;
wire [W-1:0]  r_tdata;     wire [31:0] r_tstrb; wire r_tlast, r_tvalid; reg r_tready = 0;
// ---- core side
wire          core_rst_n;
wire [9:0]    cfg_shift; wire [8:0] cfg_rows; wire [4:0] cfg_k, cfg_n;
wire          c_f_valid, c_f_last; reg c_f_ready = 0; wire [W-1:0] c_f_data;
wire          c_w_valid, c_w_last; reg c_w_ready = 0; wire [W-1:0] c_w_data;
reg           c_r_valid = 0, c_r_last = 0; wire c_r_ready; reg [W-1:0] c_r_data = 0;

GemmAxiShell #(.P_AXI_LITE_ADDR_WIDTH(AW)) dut (
    .S_AXI_ACLK(clk), .S_AXI_ARESETN(rst_n),
    .S_AXI_AWADDR(awaddr), .S_AXI_AWPROT(3'b000), .S_AXI_AWVALID(awvalid), .S_AXI_AWREADY(awready),
    .S_AXI_WDATA(wdata), .S_AXI_WSTRB(wstrb), .S_AXI_WVALID(wvalid), .S_AXI_WREADY(wready),
    .S_AXI_BRESP(bresp), .S_AXI_BVALID(bvalid), .S_AXI_BREADY(bready),
    .S_AXI_ARADDR(araddr), .S_AXI_ARPROT(3'b000), .S_AXI_ARVALID(arvalid), .S_AXI_ARREADY(arready),
    .S_AXI_RDATA(rdata), .S_AXI_RRESP(rresp), .S_AXI_RVALID(rvalid), .S_AXI_RREADY(rready),
    .irq(irq),
    .feature_axis_tready(f_tready), .feature_axis_tdata(f_tdata), .feature_axis_tstrb(f_tstrb),
    .feature_axis_tlast(f_tlast), .feature_axis_tvalid(f_tvalid),
    .weight_axis_tready(w_tready), .weight_axis_tdata(w_tdata), .weight_axis_tstrb(w_tstrb),
    .weight_axis_tlast(w_tlast), .weight_axis_tvalid(w_tvalid),
    .result_axis_tvalid(r_tvalid), .result_axis_tdata(r_tdata), .result_axis_tstrb(r_tstrb),
    .result_axis_tlast(r_tlast), .result_axis_tready(r_tready),
    .o_core_rst_n(core_rst_n), .o_cfg_shift(cfg_shift), .o_cfg_row_count(cfg_rows),
    .o_cfg_k_block_count(cfg_k), .o_cfg_n_block_count(cfg_n),
    .o_feature_valid(c_f_valid), .o_feature_last(c_f_last), .i_feature_ready(c_f_ready), .o_feature_data(c_f_data),
    .o_weight_valid(c_w_valid), .o_weight_last(c_w_last), .i_weight_ready(c_w_ready), .o_weight_data(c_w_data),
    .i_result_valid(c_r_valid), .o_result_ready(c_r_ready), .i_result_last(c_r_last), .i_result_data(c_r_data)
);

function [W-1:0] fpat(input integer i);   fpat = {8{i[31:0] ^ 32'h0F0F_0000}}; endfunction
function [W-1:0] wpat(input integer i);   wpat = {8{i[31:0] ^ 32'h00F0_F000}}; endfunction
function [W-1:0] rpat(input integer i);   rpat = {8{i[31:0] ^ 32'hA5A5_0000}}; endfunction
function rnd(input integer pct);          rnd = (($random(seed) & 32'h7fffffff) % 100) < pct; endfunction

task fail(input [8*72-1:0] what);
begin
    errors = errors + 1;
    if (errors <= 20) $display("ERROR cycle %0d: %0s", cycle, what);
end
endtask

// ---------------------------------------------------------------------------
// core model: takes NF feature and NW weight beats (checks them), then sends
// NR result beats; random ready / valid; holds its result beat while stalled
// ---------------------------------------------------------------------------
integer cf = 0, cw = 0, cr = 0;
reg     core_enable = 0;           // off during the partial-beat test
always @(posedge clk) begin
    if (core_rst_n && core_enable) begin
        if (c_f_valid && c_f_ready) begin
            if (c_f_data !== fpat(cf % NF) || c_f_last !== ((cf % NF) == NF - 1)) fail("core got a wrong feature beat");
            cf <= cf + 1;
        end
        if (c_w_valid && c_w_ready) begin
            if (c_w_data !== wpat(cw % NW) || c_w_last !== ((cw % NW) == NW - 1)) fail("core got a wrong weight beat");
            cw <= cw + 1;
        end
    end
end
always @(negedge clk) begin
    c_f_ready <= core_enable && core_rst_n && rnd(70);
    c_w_ready <= core_enable && core_rst_n && rnd(70);
end
// results: once all inputs of the current job are in. r_taken records at the
// posedge whether the beat on the bus was taken (o_result_ready is a flop in
// "reg"/"lean" and has already moved on by the next negedge).
integer job_in_f = 0, job_in_w = 0;      // input count at the start of the job
integer res_left = 0;
reg     started_results = 0;
reg     r_taken = 0;
always @(negedge clk) begin
    if (!core_rst_n) begin
        c_r_valid <= 1'b0;
    end
    else if (c_r_valid && !r_taken) begin
        // not taken yet: hold the beat (AXI-Stream rule)
    end
    else if (res_left > 0 && rnd(75)) begin
        c_r_valid <= 1'b1;
        c_r_data  <= rpat(cr % NR);
        c_r_last  <= (res_left == 1);
    end
    else
        c_r_valid <= 1'b0;
end
always @(posedge clk) begin
    r_taken <= c_r_valid && c_r_ready;
    if (c_r_valid && c_r_ready) begin
        cr <= cr + 1;
        res_left <= res_left - 1;
    end
    else if (core_enable && res_left == 0 && cf == job_in_f + NF && cw == job_in_w + NW && cr % NR == 0
             && started_results == 0) begin
        res_left <= NR;
        started_results <= 1;
    end
end
// with the core model off (partial-beat test) nothing may be offered to it
always @(posedge clk)
    if (core_rst_n && !core_enable && (c_f_valid || c_w_valid)) fail("a beat was offered to the core during the partial-beat test");

// ---------------------------------------------------------------------------
// port side checks: result beats and stability
// ---------------------------------------------------------------------------
integer pr = 0;                     // result beats accepted at the port
integer first_accept = -1, last_accept = -1;
reg prev_stall = 0; reg [W-1:0] prev_data; reg prev_last;
always @(posedge clk) begin
    if (rst_n) begin
        if (r_tvalid && r_tready) begin
            if (r_tdata !== rpat(pr % NR) || r_tlast !== ((pr % NR) == NR - 1)) fail("wrong result beat at the port");
            if (r_tstrb !== {32{1'b1}}) fail("result TSTRB not all ones");
            pr <= pr + 1;
            if (r_tlast) last_accept <= cycle;
        end
        if (prev_stall) begin
            if (!r_tvalid)            fail("result TVALID dropped while stalled");
            if (r_tdata !== prev_data) fail("result TDATA changed while stalled");
            if (r_tlast !== prev_last) fail("result TLAST changed while stalled");
        end
        prev_stall <= r_tvalid && !r_tready;
        prev_data  <= r_tdata;
        prev_last  <= r_tlast;
        if (first_accept < 0 && ((f_tvalid && f_tready) || (w_tvalid && w_tready))) first_accept <= cycle;
    end
end
always @(negedge clk) r_tready <= rnd(60);

// ---------------------------------------------------------------------------
// AXI4-Lite tasks (one transaction at a time, as the KV260 driver does)
// ---------------------------------------------------------------------------
task axil_write(input [AW-1:0] a, input [31:0] d);
begin
    @(negedge clk);
    awaddr <= a; awvalid <= 1; wdata <= d; wstrb <= 4'hF; wvalid <= 1; bready <= 1;
    @(posedge clk); while (!(awready && wready)) @(posedge clk);
    @(negedge clk); awvalid <= 0; wvalid <= 0;
    @(posedge clk); while (!bvalid) @(posedge clk);
    @(negedge clk); bready <= 0;
end
endtask

task axil_read(input [AW-1:0] a, output [31:0] d);
begin
    @(negedge clk);
    araddr <= a; arvalid <= 1; rready <= 1;
    @(posedge clk); while (!arready) @(posedge clk);
    @(negedge clk); arvalid <= 0;
    @(posedge clk); while (!rvalid) @(posedge clk);
    d = rdata;
    @(negedge clk); rready <= 0;
end
endtask

task expect_reg(input [AW-1:0] a, input [31:0] mask, input [31:0] want, input [8*40-1:0] what);
    reg [31:0] v;
begin
    axil_read(a, v);
    if ((v & mask) !== (want & mask)) begin
        errors = errors + 1;
        if (errors <= 20) $display("ERROR cycle %0d: %0s: read 0x%08h at 0x%02h, expected 0x%08h (mask 0x%08h)",
                                   cycle, what, v, a, want, mask);
    end
end
endtask

// ---------------------------------------------------------------------------
// AXIS masters: NF / NW beats with random gaps, held until accepted
// ---------------------------------------------------------------------------
task send_features;
    integer i;
begin
    for (i = 0; i < NF; i = i + 1) begin
        while (rnd(30)) @(negedge clk);
        @(negedge clk);
        f_tdata <= fpat(i); f_tlast <= (i == NF - 1); f_tstrb <= {32{1'b1}}; f_tvalid <= 1;
        @(posedge clk); while (!f_tready) @(posedge clk);
        @(negedge clk); f_tvalid <= 0; f_tlast <= 0;
    end
end
endtask

task send_weights;
    integer i;
begin
    for (i = 0; i < NW; i = i + 1) begin
        while (rnd(30)) @(negedge clk);
        @(negedge clk);
        w_tdata <= wpat(i); w_tlast <= (i == NW - 1); w_tstrb <= {32{1'b1}}; w_tvalid <= 1;
        @(posedge clk); while (!w_tready) @(posedge clk);
        @(negedge clk); w_tvalid <= 0; w_tlast <= 0;
    end
end
endtask

task run_job(input integer job, input integer clear_while_busy);
    integer t0;
    reg [31:0] v;
begin
    job_in_f = cf; job_in_w = cw;
    started_results = 0;
    first_accept = -1; last_accept = -1;
    fork
        send_features;
        send_weights;
        begin
            if (clear_while_busy) begin
                @(posedge clk); while (first_accept < 0) @(posedge clk);
                repeat (3) @(posedge clk);
                expect_reg(6'h00, 32'h0100_0000, 32'h0100_0000, "busy during the job");
                axil_write(6'h00, 32'h0001_0000);        // clear done while busy: refused
            end
        end
    join
    t0 = cycle;
    while (pr < job * NR && cycle < t0 + 20000) @(posedge clk);
    if (pr != job * NR) fail("result beats missing (timeout)");
    repeat (4) @(posedge clk);
end
endtask

reg [31:0] v;
initial begin
    repeat (4) @(posedge clk);
    @(negedge clk) rst_n = 1'b1;
    repeat (6) @(posedge clk);

    // ---- 1 registers
    axil_write(6'h00, 32'h0000_0155);
    axil_write(6'h04, 32'hFFFF_FFAB);
    axil_write(6'h08, 32'hFFFF_FFF5);
    axil_write(6'h0C, 32'h0000_000A);
    expect_reg(6'h00, 32'h0000_03FF, 32'h0000_0155, "shift readback");
    expect_reg(6'h04, 32'hFFFF_FFFF, 32'h0000_01AB, "row count: 9 bits stored");
    expect_reg(6'h08, 32'hFFFF_FFFF, 32'h0000_0015, "K blocks: 5 bits stored");
    expect_reg(6'h0C, 32'hFFFF_FFFF, 32'h0000_000A, "N blocks");
    expect_reg(6'h00, 32'h0700_0000, 32'h0400_0000, "idle, not busy, not done");
    if (cfg_shift !== 10'h155 || cfg_rows !== 9'h1AB || cfg_k !== 5'h15 || cfg_n !== 5'h0A)
        fail("cfg outputs do not follow the registers");
    expect_reg(6'h20, 32'hFFFF_FFFF, 32'h4745_4D4D, "IP_ID");
    expect_reg(6'h24, 32'hFF00_FFFF, 32'h0100_2008, "IP_VERSION major/array/width");
    expect_reg(6'h28, 32'hFFFF_FFFF, 32'h0, "unused offset 0x28");
    expect_reg(6'h3C, 32'hFFFF_FFFF, 32'h0, "unused offset 0x3C");
    axil_write(6'h10, 32'h0000_0003);
    expect_reg(6'h10, 32'hFFFF_FFFF, 32'h3, "IRQ_ENABLE readback");
    axil_write(6'h10, 32'h0000_0000);                  // off for job 1: irq must stay low
    if (irq !== 1'b0) fail("irq high before any event");

    // ---- 2/3 job 1
    core_enable = 1;
    run_job(1, 0);
    expect_reg(6'h00, 32'h0700_0000, 32'h0600_0000, "done + idle after job 1");
    expect_reg(6'h14, 32'h3, 32'h1, "IRQ_STATUS done after job 1");
    repeat (2) @(posedge clk);
    if (irq !== 1'b0) fail("irq high with IRQ_ENABLE = 0");
    axil_write(6'h10, 32'h0000_0003);                  // both interrupts on
    repeat (2) @(posedge clk);
    if (irq !== 1'b1) fail("irq not high after setting IRQ_ENABLE[0]");
    expect_reg(6'h1C, 32'hFFFF_FFFF, last_accept - first_accept + 1, "JOB_CYCLES of job 1");
    axil_read(6'h1C, v); $display("job 1: JOB_CYCLES = %0d (testbench: %0d)", v, last_accept - first_accept + 1);
    axil_write(6'h14, 32'h1);                           // W1C
    expect_reg(6'h14, 32'h3, 32'h0, "IRQ_STATUS after write-1-to-clear");
    repeat (3) @(posedge clk);
    if (irq !== 1'b0) fail("irq still high after clearing IRQ_STATUS");
    axil_write(6'h00, 32'h0001_0155);                   // clear done (accepted, not busy)
    expect_reg(6'h00, 32'h0200_0000, 32'h0, "done cleared");
    expect_reg(6'h18, 32'h7, 32'h0, "no error after a clean job");

    // ---- 4 job 2, clear-done while busy
    run_job(2, 1);
    expect_reg(6'h18, 32'h7, 32'h4, "ERROR[2]: clear refused while busy");
    expect_reg(6'h14, 32'h3, 32'h3, "IRQ_STATUS done + error after job 2");
    axil_write(6'h18, 32'h4);
    axil_write(6'h14, 32'h3);
    expect_reg(6'h18, 32'h7, 32'h0, "ERROR after W1C");
    if (cf != 2 * NF || cw != 2 * NW) fail("core did not get exactly 2 x NF / NW beats");

    // ---- 5 partial beats (the master keeps offering them; "thin" never takes
    //      them, the slices of "reg"/"lean" take one or two and then stop)
    core_enable = 0;
    @(negedge clk);
    f_tdata <= fpat(0); f_tstrb <= 32'h7FFF_FFFF; f_tlast <= 0; f_tvalid <= 1;
    repeat (8) @(posedge clk);
    expect_reg(6'h18, 32'h7, 32'h1, "ERROR[0]: feature beat, partial TSTRB");
    expect_reg(6'h14, 32'h3, 32'h2, "IRQ_STATUS[1] error");
    repeat (2) @(posedge clk);
    if (irq !== 1'b1) fail("irq not high on the error with IRQ_ENABLE[1]");
    axil_write(6'h18, 32'h1);                           // W1C while the beat is still offered
    axil_write(6'h14, 32'h2);
    repeat (4) @(posedge clk);
    expect_reg(6'h18, 32'h7, 32'h0, "ERROR[0] set again by held beat");
    expect_reg(6'h14, 32'h3, 32'h0, "IRQ_STATUS[1] set again by held beat");
    if (irq !== 1'b0) fail("irq still high after clearing the error");
    @(negedge clk); f_tvalid <= 0; f_tstrb <= {32{1'b1}};
    @(negedge clk);
    w_tdata <= wpat(0); w_tstrb <= 32'hFFFF_FFFE; w_tlast <= 0; w_tvalid <= 1;
    repeat (8) @(posedge clk);
    @(negedge clk); w_tvalid <= 0; w_tstrb <= {32{1'b1}};
    expect_reg(6'h18, 32'h7, 32'h2, "ERROR[1]: weight beat, partial TSTRB");
    expect_reg(6'h14, 32'h3, 32'h2, "IRQ_STATUS[1] on the weight error");

    $display("variant GEMM_AXIS_REG=%0d GEMM_AXIS_CG=%0d: core got %0d feature / %0d weight beats, port sent %0d results, errors %0d",
             `GEMM_AXIS_REG, `GEMM_AXIS_CG, cf, cw, pr, errors);
    $display("%s", errors == 0 ? "SHELL PASS" : "SHELL FAIL");
    $finish;
end

initial begin
    #(10 * 200000);
    $display("timeout");
    $display("SHELL FAIL");
    $finish;
end

endmodule
