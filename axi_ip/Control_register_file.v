
`timescale 1 ns / 1 ps

	module Control_register_file #
	(
		// Users to add parameters here

		// User parameters ends
		// Do not modify the parameters beyond this line


		// Parameters of Axi Slave Bus Interface S0_AXI4Lite
		parameter integer C_S0_AXI4Lite_DATA_WIDTH	= 32,
		parameter integer C_S0_AXI4Lite_ADDR_WIDTH	= 4
	)
	(
		// Users to add ports here

		// User ports ends
		// Do not modify the ports beyond this line


		// Ports of Axi Slave Bus Interface S0_AXI4Lite
		input wire  s0_axi4lite_aclk,
		input wire  s0_axi4lite_aresetn,
		input wire [C_S0_AXI4Lite_ADDR_WIDTH-1 : 0] s0_axi4lite_awaddr,
		input wire [2 : 0] s0_axi4lite_awprot,
		input wire  s0_axi4lite_awvalid,
		output wire  s0_axi4lite_awready,
		input wire [C_S0_AXI4Lite_DATA_WIDTH-1 : 0] s0_axi4lite_wdata,
		input wire [(C_S0_AXI4Lite_DATA_WIDTH/8)-1 : 0] s0_axi4lite_wstrb,
		input wire  s0_axi4lite_wvalid,
		output wire  s0_axi4lite_wready,
		output wire [1 : 0] s0_axi4lite_bresp,
		output wire  s0_axi4lite_bvalid,
		input wire  s0_axi4lite_bready,
		input wire [C_S0_AXI4Lite_ADDR_WIDTH-1 : 0] s0_axi4lite_araddr,
		input wire [2 : 0] s0_axi4lite_arprot,
		input wire  s0_axi4lite_arvalid,
		output wire  s0_axi4lite_arready,
		output wire [C_S0_AXI4Lite_DATA_WIDTH-1 : 0] s0_axi4lite_rdata,
		output wire [1 : 0] s0_axi4lite_rresp,
		output wire  s0_axi4lite_rvalid,
		input wire  s0_axi4lite_rready
	);
// Instantiation of Axi Bus Interface S0_AXI4Lite
	axi4lite_v1_0_S0_AXI4Lite # ( 
		.C_S_AXI_DATA_WIDTH(C_S0_AXI4Lite_DATA_WIDTH),
		.C_S_AXI_ADDR_WIDTH(C_S0_AXI4Lite_ADDR_WIDTH)
	) u_control_register_file_axi_lite (
		.S_AXI_ACLK(s0_axi4lite_aclk),
		.S_AXI_ARESETN(s0_axi4lite_aresetn),
		.S_AXI_AWADDR(s0_axi4lite_awaddr),
		.S_AXI_AWPROT(s0_axi4lite_awprot),
		.S_AXI_AWVALID(s0_axi4lite_awvalid),
		.S_AXI_AWREADY(s0_axi4lite_awready),
		.S_AXI_WDATA(s0_axi4lite_wdata),
		.S_AXI_WSTRB(s0_axi4lite_wstrb),
		.S_AXI_WVALID(s0_axi4lite_wvalid),
		.S_AXI_WREADY(s0_axi4lite_wready),
		.S_AXI_BRESP(s0_axi4lite_bresp),
		.S_AXI_BVALID(s0_axi4lite_bvalid),
		.S_AXI_BREADY(s0_axi4lite_bready),
		.S_AXI_ARADDR(s0_axi4lite_araddr),
		.S_AXI_ARPROT(s0_axi4lite_arprot),
		.S_AXI_ARVALID(s0_axi4lite_arvalid),
		.S_AXI_ARREADY(s0_axi4lite_arready),
		.S_AXI_RDATA(s0_axi4lite_rdata),
		.S_AXI_RRESP(s0_axi4lite_rresp),
		.S_AXI_RVALID(s0_axi4lite_rvalid),
		.S_AXI_RREADY(s0_axi4lite_rready)
	);

	// Add user logic here

	// User logic ends

	endmodule
