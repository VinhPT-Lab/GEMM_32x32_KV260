`timescale 1ns / 1ns

module tb_GEMM_top_axi_two_job_64x64_verify_copy_matrix;

localparam integer P_AXI_LITE_DATA_WIDTH = 32;
localparam integer P_AXI_LITE_ADDR_WIDTH = 4;
localparam integer P_ARRAY_SIZE = 32;
localparam integer P_DATA_WIDTH = 8;
localparam integer P_SHIFT_WIDTH = 10;
localparam integer P_BUFFER_DEPTH = 512;
localparam integer P_ACCUM_WIDTH = 32;
localparam integer P_ROW_COUNT_WIDTH = 9;
localparam integer P_K_BLOCK_COUNT_WIDTH = 5;
localparam integer P_N_BLOCK_COUNT_WIDTH = 5;

localparam integer JOB_COUNT = 2;
localparam integer M = 64;
localparam integer K = 64;
localparam integer N = 64;
localparam integer P_SHIFT = 0;

localparam integer LP_K_BLOCKS = (K + P_ARRAY_SIZE - 1) / P_ARRAY_SIZE;
localparam integer LP_N_BLOCKS = (N + P_ARRAY_SIZE - 1) / P_ARRAY_SIZE;
localparam integer LP_PADDED_K = LP_K_BLOCKS * P_ARRAY_SIZE;
localparam integer LP_PADDED_N = LP_N_BLOCKS * P_ARRAY_SIZE;
localparam integer LP_EXPECTED_FEATURE_BEATS = M * LP_K_BLOCKS;
localparam integer LP_EXPECTED_WEIGHT_BEATS = LP_PADDED_K * LP_N_BLOCKS;
localparam integer LP_EXPECTED_OUTPUT_BEATS = M * LP_N_BLOCKS;
localparam integer LP_STREAM_WORD_WIDTH = P_ARRAY_SIZE * P_DATA_WIDTH;
localparam integer P_TIMEOUT_CYCLE = 180000;

localparam [P_AXI_LITE_ADDR_WIDTH-1:0] SHIFT_ADDR = 4'h0;
localparam [P_AXI_LITE_ADDR_WIDTH-1:0] FL_ADDR    = 4'h4;
localparam [P_AXI_LITE_ADDR_WIDTH-1:0] FWBN_ADDR  = 4'h8;
localparam [P_AXI_LITE_ADDR_WIDTH-1:0] WWBN_ADDR  = 4'hC;
localparam [P_ARRAY_SIZE-1:0] FULL_TSTRB = {P_ARRAY_SIZE{1'b1}};

localparam integer STATUS_BUSY_BIT = 24;
localparam integer STATUS_DONE_BIT = 25;
localparam integer STATUS_IDLE_BIT = 26;

logic clk;
logic rst_n;

logic [P_AXI_LITE_ADDR_WIDTH-1:0] S_AXI_AWADDR;
logic [2:0] S_AXI_AWPROT;
logic S_AXI_AWVALID;
wire S_AXI_AWREADY;
logic [P_AXI_LITE_DATA_WIDTH-1:0] S_AXI_WDATA;
logic [(P_AXI_LITE_DATA_WIDTH/8)-1:0] S_AXI_WSTRB;
logic S_AXI_WVALID;
wire S_AXI_WREADY;
wire [1:0] S_AXI_BRESP;
wire S_AXI_BVALID;
logic S_AXI_BREADY;
logic [P_AXI_LITE_ADDR_WIDTH-1:0] S_AXI_ARADDR;
logic [2:0] S_AXI_ARPROT;
logic S_AXI_ARVALID;
wire S_AXI_ARREADY;
wire [P_AXI_LITE_DATA_WIDTH-1:0] S_AXI_RDATA;
wire [1:0] S_AXI_RRESP;
wire S_AXI_RVALID;
logic S_AXI_RREADY;

wire feature_axis_tready;
logic [LP_STREAM_WORD_WIDTH-1:0] feature_axis_tdata;
logic [P_ARRAY_SIZE-1:0] feature_axis_tstrb;
logic feature_axis_tlast;
logic feature_axis_tvalid;

wire weight_axis_tready;
logic [LP_STREAM_WORD_WIDTH-1:0] weight_axis_tdata;
logic [P_ARRAY_SIZE-1:0] weight_axis_tstrb;
logic weight_axis_tlast;
logic weight_axis_tvalid;

wire result_axis_tvalid;
wire [LP_STREAM_WORD_WIDTH-1:0] result_axis_tdata;
wire [P_ARRAY_SIZE-1:0] result_axis_tstrb;
wire result_axis_tlast;
logic result_axis_tready;

integer cycle;
integer current_job;
integer global_protocol_error_count;

integer job_axil_write_count [0:JOB_COUNT-1];
integer job_axil_read_count [0:JOB_COUNT-1];
integer job_feature_accept_count [0:JOB_COUNT-1];
integer job_weight_accept_count [0:JOB_COUNT-1];
integer job_result_accept_count [0:JOB_COUNT-1];
integer job_result_first_valid_cycle [0:JOB_COUNT-1];
integer job_result_tlast_accept_cycle [0:JOB_COUNT-1];
integer job_mismatch_count [0:JOB_COUNT-1];
integer job_mismatch_print_count [0:JOB_COUNT-1];
integer job_protocol_error_count [0:JOB_COUNT-1];
integer job_expected_nonzero_count [0:JOB_COUNT-1];
integer job_actual_nonzero_count [0:JOB_COUNT-1];
integer job_first_last_error_index [0:JOB_COUNT-1];
integer job_extra_result_count [0:JOB_COUNT-1];
integer job_pre_start_accept_count [0:JOB_COUNT-1];

logic [31:0] job_readback_shift [0:JOB_COUNT-1];
logic [31:0] job_readback_fl [0:JOB_COUNT-1];
logic [31:0] job_readback_fwbn [0:JOB_COUNT-1];
logic [31:0] job_readback_wwbn [0:JOB_COUNT-1];

logic job_busy_observed [0:JOB_COUNT-1];
logic job_done_observed [0:JOB_COUNT-1];
logic job_idle_after_done_observed [0:JOB_COUNT-1];
logic job_clear_done_observed [0:JOB_COUNT-1];
logic job_tlast_pass [0:JOB_COUNT-1];
logic job_output_all_zero_pass [0:JOB_COUNT-1];
logic job_pass [0:JOB_COUNT-1];
logic stale_data_pass;
logic done_cleared_between_jobs;

logic output_collection_enabled;
logic main_stream_active;
logic force_result_ready_high;

logic prev_result_stall;
logic [LP_STREAM_WORD_WIDTH-1:0] prev_result_data;
logic prev_result_last;
logic prev_feature_stall;
logic [LP_STREAM_WORD_WIDTH-1:0] prev_feature_data;
logic [P_ARRAY_SIZE-1:0] prev_feature_tstrb;
logic prev_feature_last;
logic prev_weight_stall;
logic [LP_STREAM_WORD_WIDTH-1:0] prev_weight_data;
logic [P_ARRAY_SIZE-1:0] prev_weight_tstrb;
logic prev_weight_last;

logic signed [P_DATA_WIDTH-1:0] A [0:JOB_COUNT-1][0:M-1][0:LP_PADDED_K-1];
logic signed [P_DATA_WIDTH-1:0] B [0:JOB_COUNT-1][0:LP_PADDED_K-1][0:LP_PADDED_N-1];
integer golden_q [0:JOB_COUNT-1][0:M-1][0:LP_PADDED_N-1];
integer actual_q [0:JOB_COUNT-1][0:M-1][0:LP_PADDED_N-1];

GEMM_top #(
    .P_AXI_LITE_DATA_WIDTH(P_AXI_LITE_DATA_WIDTH),
    .P_AXI_LITE_ADDR_WIDTH(P_AXI_LITE_ADDR_WIDTH),
    .P_ARRAY_SIZE(P_ARRAY_SIZE),
    .P_DATA_WIDTH(P_DATA_WIDTH),
    .P_SHIFT_WIDTH(P_SHIFT_WIDTH),
    .P_WEIGHT_BUFFER_DEPTH(P_BUFFER_DEPTH),
    .P_FEATURE_BUFFER_DEPTH(P_BUFFER_DEPTH),
    .P_OUTPUT_BUFFER_DEPTH(P_BUFFER_DEPTH),
    .P_ACCUM_WIDTH(P_ACCUM_WIDTH),
    .P_ROW_COUNT_WIDTH(P_ROW_COUNT_WIDTH),
    .P_K_BLOCK_COUNT_WIDTH(P_K_BLOCK_COUNT_WIDTH),
    .P_N_BLOCK_COUNT_WIDTH(P_N_BLOCK_COUNT_WIDTH)
) dut (
    .S_AXI_ACLK(clk),
    .S_AXI_ARESETN(rst_n),
    .S_AXI_AWADDR(S_AXI_AWADDR),
    .S_AXI_AWPROT(S_AXI_AWPROT),
    .S_AXI_AWVALID(S_AXI_AWVALID),
    .S_AXI_AWREADY(S_AXI_AWREADY),
    .S_AXI_WDATA(S_AXI_WDATA),
    .S_AXI_WSTRB(S_AXI_WSTRB),
    .S_AXI_WVALID(S_AXI_WVALID),
    .S_AXI_WREADY(S_AXI_WREADY),
    .S_AXI_BRESP(S_AXI_BRESP),
    .S_AXI_BVALID(S_AXI_BVALID),
    .S_AXI_BREADY(S_AXI_BREADY),
    .S_AXI_ARADDR(S_AXI_ARADDR),
    .S_AXI_ARPROT(S_AXI_ARPROT),
    .S_AXI_ARVALID(S_AXI_ARVALID),
    .S_AXI_ARREADY(S_AXI_ARREADY),
    .S_AXI_RDATA(S_AXI_RDATA),
    .S_AXI_RRESP(S_AXI_RRESP),
    .S_AXI_RVALID(S_AXI_RVALID),
    .S_AXI_RREADY(S_AXI_RREADY),
    .feature_axis_tready(feature_axis_tready),
    .feature_axis_tdata(feature_axis_tdata),
    .feature_axis_tstrb(feature_axis_tstrb),
    .feature_axis_tlast(feature_axis_tlast),
    .feature_axis_tvalid(feature_axis_tvalid),
    .weight_axis_tready(weight_axis_tready),
    .weight_axis_tdata(weight_axis_tdata),
    .weight_axis_tstrb(weight_axis_tstrb),
    .weight_axis_tlast(weight_axis_tlast),
    .weight_axis_tvalid(weight_axis_tvalid),
    .result_axis_tvalid(result_axis_tvalid),
    .result_axis_tdata(result_axis_tdata),
    .result_axis_tstrb(result_axis_tstrb),
    .result_axis_tlast(result_axis_tlast),
    .result_axis_tready(result_axis_tready)
);

function automatic integer quantize_to_int8(input integer value, input integer shift_amount);
    integer temp;
begin
    temp = value;
    if (shift_amount > 0)
        temp = (temp + (1 <<< (shift_amount - 1))) >>> shift_amount;
    if (temp > 127)
        temp = 127;
    else if (temp < -128)
        temp = -128;
    quantize_to_int8 = temp;
end
endfunction

function automatic signed [P_DATA_WIDTH-1:0] matrix_value_a(
    input integer job_id,
    input integer row,
    input integer col
);
    integer value;
begin
    if ((row >= M) || (col >= K)) begin
        matrix_value_a = 0;
    end
    else if (job_id == 0) begin
        value = ((row * 17 + col * 7 + (row % 5) * 3) % 29) - 14;
        matrix_value_a = value;
    end
    else begin
        if (((row * 3 + col * 5 + 1) % 11) == 0)
            matrix_value_a = 0;
        else begin
            value = ((row * 7 + col * 19 + ((row + col) % 5) * 3 + 3) % 17) - 8;
            matrix_value_a = value;
        end
    end
end
endfunction

function automatic signed [P_DATA_WIDTH-1:0] matrix_value_b(
    input integer job_id,
    input integer row,
    input integer col
);
    integer value;
begin
    if ((row >= K) || (col >= N)) begin
        matrix_value_b = 0;
    end
    else if (job_id == 0) begin
        value = ((row * 5 + col * 11 + (col % 7) * 4) % 31) - 15;
        matrix_value_b = value;
    end
    else begin
        if (row == col) begin
            case (row % 4)
                0: matrix_value_b = 8'sd2;
                1: matrix_value_b = -8'sd1;
                2: matrix_value_b = 8'sd1;
                default: matrix_value_b = -8'sd2;
            endcase
        end
        else begin
            matrix_value_b = 0;
        end
    end
end
endfunction

function automatic [LP_STREAM_WORD_WIDTH-1:0] pack_feature_word(
    input integer job_id,
    input integer word_addr
);
    integer lane;
    integer row;
    integer k_block;
    integer kk;
    reg signed [P_DATA_WIDTH-1:0] lane_value;
begin
    pack_feature_word = 0;
    row = word_addr / LP_K_BLOCKS;
    k_block = word_addr % LP_K_BLOCKS;
    for (lane = 0; lane < P_ARRAY_SIZE; lane = lane + 1) begin
        kk = k_block * P_ARRAY_SIZE + lane;
        if ((row < M) && (kk < K))
            lane_value = A[job_id][row][kk];
        else
            lane_value = 0;
        pack_feature_word[lane*P_DATA_WIDTH +: P_DATA_WIDTH] = lane_value;
    end
end
endfunction

function automatic [LP_STREAM_WORD_WIDTH-1:0] pack_weight_word(
    input integer job_id,
    input integer word_addr
);
    integer lane;
    integer kk;
    integer n_block;
    integer col;
    reg signed [P_DATA_WIDTH-1:0] lane_value;
begin
    pack_weight_word = 0;
    kk = word_addr / LP_N_BLOCKS;
    n_block = word_addr % LP_N_BLOCKS;
    for (lane = 0; lane < P_ARRAY_SIZE; lane = lane + 1) begin
        col = n_block * P_ARRAY_SIZE + lane;
        if ((kk < K) && (col < N))
            lane_value = B[job_id][kk][col];
        else
            lane_value = 0;
        pack_weight_word[lane*P_DATA_WIDTH +: P_DATA_WIDTH] = lane_value;
    end
end
endfunction

task automatic note_protocol_error;
begin
    if ((current_job >= 0) && (current_job < JOB_COUNT))
        job_protocol_error_count[current_job] = job_protocol_error_count[current_job] + 1;
    else
        global_protocol_error_count = global_protocol_error_count + 1;
end
endtask

task automatic init_job_counters(input integer job_id);
begin
    job_axil_write_count[job_id] = 0;
    job_axil_read_count[job_id] = 0;
    job_feature_accept_count[job_id] = 0;
    job_weight_accept_count[job_id] = 0;
    job_result_accept_count[job_id] = 0;
    job_result_first_valid_cycle[job_id] = -1;
    job_result_tlast_accept_cycle[job_id] = -1;
    job_mismatch_count[job_id] = 0;
    job_mismatch_print_count[job_id] = 0;
    job_protocol_error_count[job_id] = 0;
    job_actual_nonzero_count[job_id] = 0;
    job_first_last_error_index[job_id] = -1;
    job_extra_result_count[job_id] = 0;
    job_pre_start_accept_count[job_id] = 0;
    job_readback_shift[job_id] = 0;
    job_readback_fl[job_id] = 0;
    job_readback_fwbn[job_id] = 0;
    job_readback_wwbn[job_id] = 0;
    job_busy_observed[job_id] = 1'b0;
    job_done_observed[job_id] = 1'b0;
    job_idle_after_done_observed[job_id] = 1'b0;
    job_clear_done_observed[job_id] = 1'b0;
    job_tlast_pass[job_id] = 1'b0;
    job_output_all_zero_pass[job_id] = 1'b0;
    job_pass[job_id] = 1'b0;
end
endtask

task automatic init_matrices;
    integer job_id;
    integer row;
    integer col;
begin
    for (job_id = 0; job_id < JOB_COUNT; job_id = job_id + 1) begin
        for (row = 0; row < M; row = row + 1) begin
            for (col = 0; col < LP_PADDED_K; col = col + 1)
                A[job_id][row][col] = matrix_value_a(job_id, row, col);
        end
        for (row = 0; row < LP_PADDED_K; row = row + 1) begin
            for (col = 0; col < LP_PADDED_N; col = col + 1)
                B[job_id][row][col] = matrix_value_b(job_id, row, col);
        end
    end

    A[0][0][0] = 8'sd127;
    A[0][0][1] = 8'sh80;
    A[0][0][2] = 8'sd0;
    A[0][0][3] = 8'sd1;
    A[0][0][4] = -8'sd1;
    A[0][M/2][0] = 8'sh80;
    A[0][M-1][K-1] = -8'sd1;

    B[0][0][0] = 8'sd1;
    B[0][1][0] = -8'sd1;
    B[0][2][1] = 8'sd127;
    B[0][3][2] = 8'sh80;
    B[0][4][3] = 8'sd0;
    B[0][5][4] = 8'sd1;
    B[0][6][5] = -8'sd1;
    B[0][K/2][N/2] = 8'sd127;
    B[0][K-1][N-1] = -8'sd1;

    A[1][0][0] = 8'sd7;
    A[1][0][1] = -8'sd8;
    A[1][M/2][K/2] = 8'sd0;
    A[1][M-1][K-1] = -8'sd7;
end
endtask

task automatic compute_golden;
    integer job_id;
    integer row;
    integer col;
    integer kk;
    integer acc;
begin
    for (job_id = 0; job_id < JOB_COUNT; job_id = job_id + 1) begin
        job_expected_nonzero_count[job_id] = 0;
        for (row = 0; row < M; row = row + 1) begin
            for (col = 0; col < LP_PADDED_N; col = col + 1) begin
                acc = 0;
                for (kk = 0; kk < K; kk = kk + 1) begin
                    if (col < N)
                        acc = acc + A[job_id][row][kk] * B[job_id][kk][col];
                end
                golden_q[job_id][row][col] = (col < N) ? quantize_to_int8(acc, P_SHIFT) : 0;
                actual_q[job_id][row][col] = 0;
                if ((col < N) && (golden_q[job_id][row][col] != 0))
                    job_expected_nonzero_count[job_id] = job_expected_nonzero_count[job_id] + 1;
            end
        end
    end
end
endtask

task automatic remember_first_failure(
    input integer job_id,
    input integer output_index,
    input integer row,
    input integer col,
    input integer expected,
    input integer actual
);
begin
    if (job_mismatch_print_count[job_id] < 32) begin
        $display("FAIL job=%0d output mismatch row=%0d col=%0d expected=%0d actual=%0d output_index=%0d cycle=%0d",
                 job_id + 1, row, col, expected, actual, output_index, cycle);
        job_mismatch_print_count[job_id] = job_mismatch_print_count[job_id] + 1;
    end
end
endtask

task automatic axi_lite_write(input [P_AXI_LITE_ADDR_WIDTH-1:0] addr, input [31:0] data);
    bit aw_done;
    bit w_done;
begin
    @(posedge clk);
    S_AXI_AWADDR <= addr;
    S_AXI_AWPROT <= 3'b000;
    S_AXI_AWVALID <= 1'b1;
    S_AXI_WDATA <= data;
    S_AXI_WSTRB <= 4'hF;
    S_AXI_WVALID <= 1'b1;
    S_AXI_BREADY <= 1'b1;
    aw_done = 1'b0;
    w_done = 1'b0;
    while (!(aw_done && w_done)) begin
        @(posedge clk);
        if (!aw_done && S_AXI_AWREADY) begin
            aw_done = 1'b1;
            S_AXI_AWVALID <= 1'b0;
        end
        if (!w_done && S_AXI_WREADY) begin
            w_done = 1'b1;
            S_AXI_WVALID <= 1'b0;
        end
    end
    do @(posedge clk); while (!S_AXI_BVALID);
    if (S_AXI_BRESP != 2'b00) begin
        note_protocol_error();
        $display("FAIL AXI-Lite write BRESP job=%0d addr=0x%0h resp=%0d cycle=%0d",
                 current_job + 1, addr, S_AXI_BRESP, cycle);
    end
    if ((current_job >= 0) && (current_job < JOB_COUNT))
        job_axil_write_count[current_job] = job_axil_write_count[current_job] + 1;
    $display("AXIL_WRITE_DONE job=%0d addr=0x%0h data=0x%08h cycle=%0d",
             current_job + 1, addr, data, cycle);
    @(posedge clk);
    S_AXI_BREADY <= 1'b0;
    S_AXI_AWADDR <= 0;
    S_AXI_WDATA <= 0;
end
endtask

task automatic axi_lite_read(input [P_AXI_LITE_ADDR_WIDTH-1:0] addr, output [31:0] data);
begin
    @(posedge clk);
    S_AXI_ARADDR <= addr;
    S_AXI_ARPROT <= 3'b000;
    S_AXI_ARVALID <= 1'b1;
    S_AXI_RREADY <= 1'b1;
    do @(posedge clk); while (!S_AXI_ARREADY);
    S_AXI_ARVALID <= 1'b0;
    do @(posedge clk); while (!(S_AXI_RVALID && S_AXI_RREADY));
    data = S_AXI_RDATA;
    if (S_AXI_RRESP != 2'b00) begin
        note_protocol_error();
        $display("FAIL AXI-Lite read RRESP job=%0d addr=0x%0h resp=%0d cycle=%0d",
                 current_job + 1, addr, S_AXI_RRESP, cycle);
    end
    if ((current_job >= 0) && (current_job < JOB_COUNT))
        job_axil_read_count[current_job] = job_axil_read_count[current_job] + 1;
    $display("AXIL_READ_DONE job=%0d addr=0x%0h data=0x%08h cycle=%0d",
             current_job + 1, addr, data, cycle);
    @(posedge clk);
    S_AXI_RREADY <= 1'b0;
    S_AXI_ARADDR <= 0;
end
endtask

task automatic check_readback(
    input integer job_id,
    input [P_AXI_LITE_ADDR_WIDTH-1:0] addr,
    input [31:0] mask,
    input [31:0] expected
);
    reg [31:0] data;
begin
    axi_lite_read(addr, data);
    if (addr == SHIFT_ADDR)
        job_readback_shift[job_id] = data;
    else if (addr == FL_ADDR)
        job_readback_fl[job_id] = data;
    else if (addr == FWBN_ADDR)
        job_readback_fwbn[job_id] = data;
    else if (addr == WWBN_ADDR)
        job_readback_wwbn[job_id] = data;

    $display("CONFIG_READBACK job=%0d addr=0x%0h raw=0x%08h masked=0x%08h expected=0x%08h cycle=%0d",
             job_id + 1, addr, data, data & mask, expected, cycle);
    if ((data & mask) !== expected) begin
        note_protocol_error();
        $display("FAIL AXI-Lite readback job=%0d addr=0x%0h expected=0x%0h actual=0x%0h raw=0x%0h",
                 job_id + 1, addr, expected, data & mask, data);
    end
end
endtask

task automatic write_and_check_config(input integer job_id);
begin
    axi_lite_write(SHIFT_ADDR, P_SHIFT);
    axi_lite_write(FL_ADDR, M);
    axi_lite_write(FWBN_ADDR, LP_K_BLOCKS);
    axi_lite_write(WWBN_ADDR, LP_N_BLOCKS);
    check_readback(job_id, SHIFT_ADDR, 32'h0000_03FF, P_SHIFT);
    check_readback(job_id, FL_ADDR, 32'h0000_01FF, M);
    check_readback(job_id, FWBN_ADDR, 32'h0000_001F, LP_K_BLOCKS);
    check_readback(job_id, WWBN_ADDR, 32'h0000_001F, LP_N_BLOCKS);
end
endtask

task automatic check_idle_before_job(input integer job_id);
    reg [31:0] status;
begin
    axi_lite_read(SHIFT_ADDR, status);
    if (!status[STATUS_IDLE_BIT]) begin
        note_protocol_error();
        $display("FAIL idle status not high before job=%0d status=0x%0h cycle=%0d",
                 job_id + 1, status, cycle);
    end
end
endtask

task automatic check_busy_during_job(input integer job_id);
    reg [31:0] status;
begin
    wait ((job_feature_accept_count[job_id] > 4) && (job_weight_accept_count[job_id] > 4));
    repeat (3) @(posedge clk);
    axi_lite_read(SHIFT_ADDR, status);
    if (status[STATUS_BUSY_BIT])
        job_busy_observed[job_id] = 1'b1;
    else begin
        note_protocol_error();
        $display("FAIL busy status not observed job=%0d status=0x%0h cycle=%0d",
                 job_id + 1, status, cycle);
    end
end
endtask

task automatic check_done_and_clear_status(input integer job_id);
    reg [31:0] status;
begin
    force_result_ready_high <= 1'b1;
    repeat (30) @(posedge clk);
    axi_lite_read(SHIFT_ADDR, status);
    if (status[STATUS_DONE_BIT])
        job_done_observed[job_id] = 1'b1;
    else begin
        note_protocol_error();
        $display("FAIL done status not observed job=%0d status=0x%0h cycle=%0d",
                 job_id + 1, status, cycle);
    end
    if (status[STATUS_IDLE_BIT])
        job_idle_after_done_observed[job_id] = 1'b1;
    else begin
        note_protocol_error();
        $display("FAIL idle after done not observed job=%0d status=0x%0h cycle=%0d",
                 job_id + 1, status, cycle);
    end

    axi_lite_write(SHIFT_ADDR, 32'h0001_0000);
    repeat (3) @(posedge clk);
    axi_lite_read(SHIFT_ADDR, status);
    if (!status[STATUS_DONE_BIT])
        job_clear_done_observed[job_id] = 1'b1;
    else begin
        note_protocol_error();
        $display("FAIL done status did not clear job=%0d status=0x%0h cycle=%0d",
                 job_id + 1, status, cycle);
    end
    force_result_ready_high <= 1'b0;
end
endtask

task automatic drive_feature_stream(input integer job_id);
    integer word_addr;
    integer gap_count;
begin
    for (word_addr = 0; word_addr < LP_EXPECTED_FEATURE_BEATS; word_addr = word_addr + 1) begin
        gap_count = (word_addr * (job_id + 5) + job_id + 1) % 4;
        repeat (gap_count) @(posedge clk);
        @(posedge clk);
        feature_axis_tdata <= pack_feature_word(job_id, word_addr);
        feature_axis_tstrb <= FULL_TSTRB;
        feature_axis_tlast <= (word_addr == LP_EXPECTED_FEATURE_BEATS - 1);
        feature_axis_tvalid <= 1'b1;
        do @(posedge clk); while (!feature_axis_tready);
        feature_axis_tvalid <= 1'b0;
        feature_axis_tlast <= 1'b0;
    end
    @(posedge clk);
    feature_axis_tdata <= 0;
    feature_axis_tstrb <= FULL_TSTRB;
    feature_axis_tlast <= 1'b0;
end
endtask

task automatic drive_weight_stream(input integer job_id);
    integer word_addr;
    integer gap_count;
begin
    for (word_addr = 0; word_addr < LP_EXPECTED_WEIGHT_BEATS; word_addr = word_addr + 1) begin
        gap_count = (word_addr * (job_id + 7) + job_id + 2) % 5;
        repeat (gap_count) @(posedge clk);
        @(posedge clk);
        weight_axis_tdata <= pack_weight_word(job_id, word_addr);
        weight_axis_tstrb <= FULL_TSTRB;
        weight_axis_tlast <= (word_addr == LP_EXPECTED_WEIGHT_BEATS - 1);
        weight_axis_tvalid <= 1'b1;
        do @(posedge clk); while (!weight_axis_tready);
        weight_axis_tvalid <= 1'b0;
        weight_axis_tlast <= 1'b0;
    end
    @(posedge clk);
    weight_axis_tdata <= 0;
    weight_axis_tstrb <= FULL_TSTRB;
    weight_axis_tlast <= 1'b0;
end
endtask

task automatic print_result_matrix(input integer job_id);
    integer row;
    integer col;
begin
    // Copy the complete block from MATRIX_BEGIN to MATRIX_END into
    // result_matrix.txt. Each matrix row contains exactly N integers.
    $display("");
    $display("MATRIX_BEGIN JOB=%0d ROWS=%0d COLS=%0d", job_id + 1, M, N);

    for (row = 0; row < M; row = row + 1) begin
        for (col = 0; col < N; col = col + 1) begin
            if (col == 0)
                $write("%0d", actual_q[job_id][row][col]);
            else
                $write(" %0d", actual_q[job_id][row][col]);
        end
        $display("");
    end

    $display("MATRIX_END JOB=%0d", job_id + 1);
    $display("");
end
endtask

task automatic print_job_summary(input integer job_id);
begin
    job_tlast_pass[job_id] = (job_first_last_error_index[job_id] < 0) &&
                             (job_result_tlast_accept_cycle[job_id] >= 0);
    job_output_all_zero_pass[job_id] = (job_expected_nonzero_count[job_id] == 0) ||
                                       (job_actual_nonzero_count[job_id] != 0);
    job_pass[job_id] = (job_feature_accept_count[job_id] == LP_EXPECTED_FEATURE_BEATS) &&
                       (job_weight_accept_count[job_id] == LP_EXPECTED_WEIGHT_BEATS) &&
                       (job_result_accept_count[job_id] == LP_EXPECTED_OUTPUT_BEATS) &&
                       (job_mismatch_count[job_id] == 0) &&
                       (job_protocol_error_count[job_id] == 0) &&
                       (job_extra_result_count[job_id] == 0) &&
                       job_tlast_pass[job_id] &&
                       job_output_all_zero_pass[job_id] &&
                       job_busy_observed[job_id] &&
                       job_done_observed[job_id] &&
                       job_idle_after_done_observed[job_id] &&
                       job_clear_done_observed[job_id];

    $display("JOB_ID = %0d", job_id + 1);
    $display("AXI-Lite readback SHIFT = 0x%08h", job_readback_shift[job_id]);
    $display("AXI-Lite readback FL = 0x%08h", job_readback_fl[job_id]);
    $display("AXI-Lite readback FWBN = 0x%08h", job_readback_fwbn[job_id]);
    $display("AXI-Lite readback WWBN = 0x%08h", job_readback_wwbn[job_id]);
    $display("Feature accepted beats = %0d", job_feature_accept_count[job_id]);
    $display("Expected feature beats = %0d", LP_EXPECTED_FEATURE_BEATS);
    $display("Weight accepted beats = %0d", job_weight_accept_count[job_id]);
    $display("Expected weight beats = %0d", LP_EXPECTED_WEIGHT_BEATS);
    $display("Result first valid cycle = %0d", job_result_first_valid_cycle[job_id]);
    $display("Result accepted beats = %0d", job_result_accept_count[job_id]);
    $display("Expected result beats = %0d", LP_EXPECTED_OUTPUT_BEATS);
    $display("Mismatch count = %0d", job_mismatch_count[job_id]);
    $display("Protocol error count = %0d", job_protocol_error_count[job_id]);
    $display("TLAST check = %s", job_tlast_pass[job_id] ? "PASS" : "FAIL");
    $display("Output all zero check = %s", job_output_all_zero_pass[job_id] ? "PASS" : "FAIL");
    $display("Busy observed = %0d", job_busy_observed[job_id]);
    $display("Done observed = %0d", job_done_observed[job_id]);
    $display("Clear done observed = %0d", job_clear_done_observed[job_id]);
    $display("%s", job_pass[job_id] ? "PASS" : "FAIL");
end
endtask

task automatic run_one_job(input integer job_id);
    bit job_timeout_seen;
begin
    current_job = job_id;
    init_job_counters(job_id);
    output_collection_enabled <= 1'b0;
    main_stream_active <= 1'b0;
    force_result_ready_high <= 1'b0;
    repeat (5) @(posedge clk);

    $display("JOB_%0d_START cycle=%0d", job_id + 1, cycle);
    write_and_check_config(job_id);
    check_idle_before_job(job_id);

    output_collection_enabled <= 1'b1;
    main_stream_active <= 1'b1;
    job_timeout_seen = 1'b0;

    fork
        drive_feature_stream(job_id);
        drive_weight_stream(job_id);
        check_busy_during_job(job_id);
    join_none

    fork
        begin
            wait (job_result_accept_count[job_id] == LP_EXPECTED_OUTPUT_BEATS);
        end
        begin
            repeat (P_TIMEOUT_CYCLE) @(posedge clk);
            job_timeout_seen = 1'b1;
            note_protocol_error();
            $display("FAIL timeout waiting for expected output beats job=%0d feature=%0d/%0d weight=%0d/%0d result=%0d/%0d cycle=%0d",
                     job_id + 1,
                     job_feature_accept_count[job_id], LP_EXPECTED_FEATURE_BEATS,
                     job_weight_accept_count[job_id], LP_EXPECTED_WEIGHT_BEATS,
                     job_result_accept_count[job_id], LP_EXPECTED_OUTPUT_BEATS,
                     cycle);
        end
    join_any
    disable fork;

    if (!job_timeout_seen) begin
        force_result_ready_high <= 1'b1;
        repeat (20) @(posedge clk);
        check_done_and_clear_status(job_id);
    end

    output_collection_enabled <= 1'b0;
    main_stream_active <= 1'b0;
    force_result_ready_high <= 1'b0;
    repeat (10) @(posedge clk);
    print_result_matrix(job_id);
    print_job_summary(job_id);
    $display("JOB_%0d_END cycle=%0d", job_id + 1, cycle);
    current_job = -1;
end
endtask

task automatic compute_stale_data_check;
    integer row;
    integer col;
    integer actual_equal_count;
    integer golden_equal_count;
begin
    actual_equal_count = 0;
    golden_equal_count = 0;
    for (row = 0; row < M; row = row + 1) begin
        for (col = 0; col < N; col = col + 1) begin
            if (actual_q[0][row][col] == actual_q[1][row][col])
                actual_equal_count = actual_equal_count + 1;
            if (golden_q[0][row][col] == golden_q[1][row][col])
                golden_equal_count = golden_equal_count + 1;
        end
    end
    stale_data_pass = (job_pass[0] && job_pass[1] &&
                       (golden_equal_count < M*N) &&
                       (actual_equal_count < M*N));
    done_cleared_between_jobs = job_clear_done_observed[0];
    $display("Job output equal element count = %0d", actual_equal_count);
    $display("Golden output equal element count = %0d", golden_equal_count);
end
endtask

task automatic print_final_summary;
    logic overall_pass;
begin
    compute_stale_data_check();
    overall_pass = job_pass[0] && job_pass[1] && stale_data_pass &&
                   (global_protocol_error_count == 0);

    $display("Two-job stale data check: %s", stale_data_pass ? "PASS" : "FAIL");
    $display("Job 1 PASS / FAIL: %s", job_pass[0] ? "PASS" : "FAIL");
    $display("Job 2 PASS / FAIL: %s", job_pass[1] ? "PASS" : "FAIL");
    $display("DUT reset between jobs: NO");
    $display("Done/status cleared between jobs: %s", done_cleared_between_jobs ? "YES" : "NO");
    $display("Overall PASS / FAIL: %s", overall_pass ? "PASS" : "FAIL");
    if (overall_pass)
        $display("OVERALL PASS");
    else
        $display("OVERALL FAIL");
end
endtask

always #5 clk = ~clk;

always @(posedge clk or negedge rst_n) begin
    if (!rst_n)
        result_axis_tready <= 1'b0;
    else if (force_result_ready_high)
        result_axis_tready <= 1'b1;
    else if (output_collection_enabled)
        result_axis_tready <= (((cycle + current_job*3) % 7) != 0) &&
                              (((cycle + current_job*5) % 11) != 0);
    else
        result_axis_tready <= 1'b0;
end

always @(posedge clk or negedge rst_n) begin
    if (!rst_n)
        cycle <= 0;
    else
        cycle <= cycle + 1;
end

always @(posedge clk) begin
    integer job_id;
    integer row;
    integer col;
    integer lane;
    integer n_block;
    integer actual;
    integer expected;

    if (rst_n) begin
        job_id = current_job;

        if (feature_axis_tvalid && feature_axis_tready) begin
            if (main_stream_active && (job_id >= 0) && (job_id < JOB_COUNT)) begin
                job_feature_accept_count[job_id] = job_feature_accept_count[job_id] + 1;
                $display("FEATURE_ACCEPT job=%0d beat=%0d tlast=%0b tstrb=0x%08h cycle=%0d",
                         job_id + 1, job_feature_accept_count[job_id],
                         feature_axis_tlast, feature_axis_tstrb, cycle);
                if (feature_axis_tstrb !== FULL_TSTRB) begin
                    note_protocol_error();
                    $display("FAIL feature TSTRB not full job=%0d beat=%0d",
                             job_id + 1, job_feature_accept_count[job_id]);
                end
                if (feature_axis_tlast !== (job_feature_accept_count[job_id] == LP_EXPECTED_FEATURE_BEATS)) begin
                    note_protocol_error();
                    $display("FAIL feature TLAST mismatch job=%0d beat=%0d expected=%0d actual=%0d",
                             job_id + 1, job_feature_accept_count[job_id],
                             (job_feature_accept_count[job_id] == LP_EXPECTED_FEATURE_BEATS),
                             feature_axis_tlast);
                end
            end
        end

        if (weight_axis_tvalid && weight_axis_tready) begin
            if (main_stream_active && (job_id >= 0) && (job_id < JOB_COUNT)) begin
                job_weight_accept_count[job_id] = job_weight_accept_count[job_id] + 1;
                $display("WEIGHT_ACCEPT job=%0d beat=%0d tlast=%0b tstrb=0x%08h cycle=%0d",
                         job_id + 1, job_weight_accept_count[job_id],
                         weight_axis_tlast, weight_axis_tstrb, cycle);
                if (weight_axis_tstrb !== FULL_TSTRB) begin
                    note_protocol_error();
                    $display("FAIL weight TSTRB not full job=%0d beat=%0d",
                             job_id + 1, job_weight_accept_count[job_id]);
                end
                if (weight_axis_tlast !== (job_weight_accept_count[job_id] == LP_EXPECTED_WEIGHT_BEATS)) begin
                    note_protocol_error();
                    $display("FAIL weight TLAST mismatch job=%0d beat=%0d expected=%0d actual=%0d",
                             job_id + 1, job_weight_accept_count[job_id],
                             (job_weight_accept_count[job_id] == LP_EXPECTED_WEIGHT_BEATS),
                             weight_axis_tlast);
                end
            end
        end

        if (prev_result_stall && result_axis_tvalid && !result_axis_tready) begin
            if (result_axis_tdata !== prev_result_data) begin
                note_protocol_error();
                $display("FAIL result data changed under backpressure job=%0d cycle=%0d", job_id + 1, cycle);
            end
            if (result_axis_tlast !== prev_result_last) begin
                note_protocol_error();
                $display("FAIL result TLAST changed under backpressure job=%0d cycle=%0d", job_id + 1, cycle);
            end
        end

        if (prev_feature_stall && feature_axis_tvalid && !feature_axis_tready) begin
            if ((feature_axis_tdata !== prev_feature_data) ||
                (feature_axis_tstrb !== prev_feature_tstrb) ||
                (feature_axis_tlast !== prev_feature_last)) begin
                note_protocol_error();
                $display("FAIL feature source changed under backpressure job=%0d cycle=%0d", job_id + 1, cycle);
            end
        end

        if (prev_weight_stall && weight_axis_tvalid && !weight_axis_tready) begin
            if ((weight_axis_tdata !== prev_weight_data) ||
                (weight_axis_tstrb !== prev_weight_tstrb) ||
                (weight_axis_tlast !== prev_weight_last)) begin
                note_protocol_error();
                $display("FAIL weight source changed under backpressure job=%0d cycle=%0d", job_id + 1, cycle);
            end
        end

        if (result_axis_tvalid && (result_axis_tstrb !== FULL_TSTRB)) begin
            note_protocol_error();
            $display("FAIL result TSTRB not full job=%0d cycle=%0d", job_id + 1, cycle);
        end

        if (output_collection_enabled && (job_id >= 0) && (job_id < JOB_COUNT) &&
            result_axis_tvalid && (job_result_first_valid_cycle[job_id] < 0)) begin
            job_result_first_valid_cycle[job_id] = cycle;
            $display("RESULT_VALID_FIRST job=%0d cycle=%0d", job_id + 1, cycle);
        end

        if (!output_collection_enabled && result_axis_tvalid && result_axis_tready &&
            (job_id >= 0) && (job_id < JOB_COUNT)) begin
            job_pre_start_accept_count[job_id] = job_pre_start_accept_count[job_id] + 1;
            note_protocol_error();
            $display("FAIL result accepted outside collection window job=%0d cycle=%0d", job_id + 1, cycle);
        end
        else if (output_collection_enabled && (job_id >= 0) && (job_id < JOB_COUNT) &&
                 result_axis_tvalid && result_axis_tready) begin
            $display("RESULT_ACCEPT job=%0d beat=%0d tlast=%0b cycle=%0d",
                     job_id + 1, job_result_accept_count[job_id] + 1,
                     result_axis_tlast, cycle);
            if (result_axis_tlast && (job_result_tlast_accept_cycle[job_id] < 0))
                job_result_tlast_accept_cycle[job_id] = cycle;

            if (job_result_accept_count[job_id] >= LP_EXPECTED_OUTPUT_BEATS) begin
                note_protocol_error();
                job_extra_result_count[job_id] = job_extra_result_count[job_id] + 1;
                $display("FAIL extra result beat job=%0d output_index=%0d cycle=%0d",
                         job_id + 1, job_result_accept_count[job_id], cycle);
            end
            else begin
                row = job_result_accept_count[job_id] / LP_N_BLOCKS;
                n_block = job_result_accept_count[job_id] % LP_N_BLOCKS;
                for (lane = 0; lane < P_ARRAY_SIZE; lane = lane + 1) begin
                    col = n_block * P_ARRAY_SIZE + lane;
                    actual = $signed(result_axis_tdata[lane*P_DATA_WIDTH +: P_DATA_WIDTH]);
                    expected = (col < N) ? golden_q[job_id][row][col] : 0;
                    actual_q[job_id][row][col] = actual;
                    if ((col < N) && (actual != 0))
                        job_actual_nonzero_count[job_id] = job_actual_nonzero_count[job_id] + 1;
                    if (actual !== expected) begin
                        job_mismatch_count[job_id] = job_mismatch_count[job_id] + 1;
                        remember_first_failure(job_id, job_result_accept_count[job_id],
                                               row, col, expected, actual);
                    end
                end
            end

            if (result_axis_tlast !== (job_result_accept_count[job_id] == LP_EXPECTED_OUTPUT_BEATS - 1)) begin
                note_protocol_error();
                if (job_first_last_error_index[job_id] < 0)
                    job_first_last_error_index[job_id] = job_result_accept_count[job_id];
                $display("FAIL result TLAST mismatch job=%0d expected=%0d actual=%0d output_index=%0d cycle=%0d",
                         job_id + 1,
                         (job_result_accept_count[job_id] == LP_EXPECTED_OUTPUT_BEATS - 1),
                         result_axis_tlast, job_result_accept_count[job_id], cycle);
            end

            job_result_accept_count[job_id] = job_result_accept_count[job_id] + 1;
        end

        prev_result_stall <= result_axis_tvalid && !result_axis_tready;
        prev_result_data <= result_axis_tdata;
        prev_result_last <= result_axis_tlast;
        prev_feature_stall <= feature_axis_tvalid && !feature_axis_tready;
        prev_feature_data <= feature_axis_tdata;
        prev_feature_tstrb <= feature_axis_tstrb;
        prev_feature_last <= feature_axis_tlast;
        prev_weight_stall <= weight_axis_tvalid && !weight_axis_tready;
        prev_weight_data <= weight_axis_tdata;
        prev_weight_tstrb <= weight_axis_tstrb;
        prev_weight_last <= weight_axis_tlast;
    end
end

initial begin
    integer job_id;

    clk = 0;
    rst_n = 0;
    current_job = -1;
    global_protocol_error_count = 0;
    stale_data_pass = 1'b0;
    done_cleared_between_jobs = 1'b0;

    S_AXI_AWADDR = 0;
    S_AXI_AWPROT = 0;
    S_AXI_AWVALID = 0;
    S_AXI_WDATA = 0;
    S_AXI_WSTRB = 0;
    S_AXI_WVALID = 0;
    S_AXI_BREADY = 0;
    S_AXI_ARADDR = 0;
    S_AXI_ARPROT = 0;
    S_AXI_ARVALID = 0;
    S_AXI_RREADY = 0;

    feature_axis_tdata = 0;
    feature_axis_tstrb = FULL_TSTRB;
    feature_axis_tlast = 0;
    feature_axis_tvalid = 0;
    weight_axis_tdata = 0;
    weight_axis_tstrb = FULL_TSTRB;
    weight_axis_tlast = 0;
    weight_axis_tvalid = 0;
    result_axis_tready = 0;

    cycle = 0;
    output_collection_enabled = 0;
    main_stream_active = 0;
    force_result_ready_high = 0;
    prev_result_stall = 0;
    prev_result_data = 0;
    prev_result_last = 0;
    prev_feature_stall = 0;
    prev_feature_data = 0;
    prev_feature_tstrb = 0;
    prev_feature_last = 0;
    prev_weight_stall = 0;
    prev_weight_data = 0;
    prev_weight_tstrb = 0;
    prev_weight_last = 0;

    for (job_id = 0; job_id < JOB_COUNT; job_id = job_id + 1)
        init_job_counters(job_id);

    init_matrices();
    compute_golden();

    $display("TEST START");
    $display("Testbench = tb_GEMM_top_axi_two_job_64x64_verify");
    $display("DUT = GEMM_top");
    $display("DUT reset between jobs = NO");
    $display("Array size: %0dx%0d", P_ARRAY_SIZE, P_ARRAY_SIZE);
    $display("Logical matrix size: A=%0dx%0d B=%0dx%0d C=%0dx%0d", M, K, K, N, M, N);
    $display("Config values: shift=%0d row_count=%0d k_block_count=%0d n_block_count=%0d",
             P_SHIFT, M, LP_K_BLOCKS, LP_N_BLOCKS);
    $display("Expected feature beat count = %0d", LP_EXPECTED_FEATURE_BEATS);
    $display("Expected weight beat count = %0d", LP_EXPECTED_WEIGHT_BEATS);
    $display("Expected output beat count = %0d", LP_EXPECTED_OUTPUT_BEATS);

    repeat (8) @(posedge clk);
    rst_n <= 1'b1;
    repeat (8) @(posedge clk);

    run_one_job(0);
    $display("NO_DUT_RESET_BETWEEN_JOBS cycle=%0d", cycle);
    run_one_job(1);

    print_final_summary();
    $finish;
end

endmodule
