`timescale 1ns / 1ps
// per-cycle trace of job 1 (debug only, RTL hierarchy)
module trace_mon;
`define TB tb_GEMM_top_axi_two_job_64x64_verify_copy_matrix
`define BF `TB.dut.u_gemm_accelerator.u_buffer_feeder
`define IB `TB.dut.u_gemm_accelerator.u_input_buffer
`define OB `TB.dut.u_gemm_accelerator.u_output_buffer
    always @(posedge `TB.clk) if (`TB.current_job == 0 && `TB.cycle < 700 &&
        (`IB.o_buffer_feature_valid || `BF.state != 0 || `BF.output_feature_valid || `BF.input_feature_valid))
        $display("TR c=%0d IBfv=%b IBfl=%b IBrow=%0d IBkb=%0d IBcnt=%0d | BFst=%0d fv=%b fl=%b fcnt=%0d faddr=%0d wld=%b | cin_v=%b cin_l=%b | out_v=%b out_l=%b w_end=%b tot_last=%b",
          `TB.cycle, `IB.o_buffer_feature_valid, `IB.o_buffer_feature_last, `IB.r_feature_read_row, `IB.r_feature_read_k_block, `IB.r_buffer_feature_count,
          `BF.state, `BF.input_feature_valid, `BF.input_feature_last, `BF.feature_cnt, `BF.input_feature_addr, `BF.r_weight_loaded_d1,
          `BF.r_compute_input_valid, `BF.r_compute_input_last, `BF.output_feature_valid, `BF.output_feature_last, `BF.w_end, `BF.total_last);
endmodule
