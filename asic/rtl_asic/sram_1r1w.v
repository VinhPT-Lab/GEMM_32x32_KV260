`timescale 1ns / 1ps
// ---------------------------------------------------------------------------
// sram_1r1w  -  one write port + one read port, synchronous read (1 cycle).
//
// Every buffer memory in the design goes through this wrapper so the memory
// technology can be swapped in ONE place.
//
//  * Default (no define): behavioural model. Same semantics as the original
//    `reg [...] mem [...]` code: write on posedge when i_we, registered read
//    when i_re, read-old-data on a same-address collision, and o_rdata HOLDS
//    its value while i_re = 0 (OutputBuffer relies on that during
//    back-pressure).
//
//  * `define SRAM_USE_SKY130_OPENRAM: tiles sky130 OpenRAM macros
//    sky130_sram_2kbyte_1rw1r_32x512_8 (port0 = write only, port1 = read).
//    NB x NL macros, NB = ceil(depth/512), NL = ceil(width/32).
//    Things to check before trusting this branch:
//      - port names against the .v/.lef shipped with YOUR PDK install;
//      - OpenRAM drives dout after the FALLING edge, so logic after o_rdata
//        gets only ~half a cycle. If STA fails, lower the clock or add a
//        pipeline stage after the SRAM (and re-align the control logic);
//      - same-address read+write on the two ports is not defined for these
//        macros. The GEMM buffers never rely on that value, but keep it in
//        mind if you change the control logic;
//      - power pins are connected by ORFS global_connect, not in Verilog.
//    Also: SYNTH_MEMORY_MAX_BITS in ORFS will stop synthesis if a memory
//    this big slips through as flip-flops - that error is your friend.
// ---------------------------------------------------------------------------
module sram_1r1w
#(
    parameter integer P_WIDTH      = 256,
    parameter integer P_DEPTH      = 512,
    parameter integer P_ADDR_WIDTH = (P_DEPTH <= 1) ? 1 : $clog2(P_DEPTH)
)
(
    input                     i_clk,
    input                     i_we,
    input  [P_ADDR_WIDTH-1:0] i_waddr,
    input  [P_WIDTH-1:0]      i_wdata,
    input                     i_re,
    input  [P_ADDR_WIDTH-1:0] i_raddr,
    output [P_WIDTH-1:0]      o_rdata
);

`ifndef SRAM_USE_SKY130_OPENRAM
// ------------------------------------------------------------ behavioural --
reg [P_WIDTH-1:0] r_mem [0:P_DEPTH-1];
reg [P_WIDTH-1:0] r_rdata;

always @(posedge i_clk)
    if (i_we) r_mem[i_waddr] <= i_wdata;

always @(posedge i_clk)
    if (i_re) r_rdata <= r_mem[i_raddr];

assign o_rdata = r_rdata;

`else
// ------------------------------------------------------ sky130 OpenRAM ----
localparam integer LP_MW  = 32;    // macro data width
localparam integer LP_MD  = 512;   // macro depth
localparam integer LP_MAW = 9;     // macro address width
localparam integer LP_NL  = (P_WIDTH + LP_MW - 1) / LP_MW;   // lanes
localparam integer LP_NB  = (P_DEPTH + LP_MD - 1) / LP_MD;   // banks
localparam integer LP_BAW = (LP_NB <= 1) ? 1 : $clog2(LP_NB);

wire [LP_MAW-1:0]            w_wa = i_waddr;                 // zero-ext / truncate
wire [LP_MAW-1:0]            w_ra = i_raddr;
wire [LP_BAW-1:0]            w_wb = (LP_NB > 1) ? (i_waddr >> LP_MAW) : 0;
wire [LP_BAW-1:0]            w_rb = (LP_NB > 1) ? (i_raddr >> LP_MAW) : 0;
wire [LP_NL*LP_MW-1:0]       w_wdata_pad = i_wdata;
wire [LP_NB*LP_NL*LP_MW-1:0] w_dout_all;

reg  [LP_BAW-1:0]            r_rb;
reg                          r_re_d;
reg  [P_WIDTH-1:0]           r_hold;
wire [P_WIDTH-1:0]           w_macro_rdata = w_dout_all[r_rb*LP_NL*LP_MW +: P_WIDTH];

genvar b, l;
generate
    for (b = 0; b < LP_NB; b = b + 1) begin : g_bank
        for (l = 0; l < LP_NL; l = l + 1) begin : g_lane
            sky130_sram_2kbyte_1rw1r_32x512_8 u_macro (
                .clk0   (i_clk),
                .csb0   (~(i_we && (w_wb == b))),
                .web0   (1'b0),
                .wmask0 (4'hF),
                .addr0  (w_wa),
                .din0   (w_wdata_pad[l*LP_MW +: LP_MW]),
                .dout0  (),
                .clk1   (i_clk),
                .csb1   (~(i_re && (w_rb == b))),
                .addr1  (w_ra),
                .dout1  (w_dout_all[(b*LP_NL + l)*LP_MW +: LP_MW])
            );
        end
    end
endgenerate

always @(posedge i_clk) begin
    r_re_d <= i_re;
    if (i_re)   r_rb   <= w_rb;
    if (r_re_d) r_hold <= w_macro_rdata;
end

// hold last read data while i_re is low (macro output is not guaranteed to)
assign o_rdata = r_re_d ? w_macro_rdata : r_hold;
`endif

endmodule
