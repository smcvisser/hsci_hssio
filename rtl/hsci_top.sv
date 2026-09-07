// ***************************************************************************
//  hsci_top.sv
//
//  Connects ADI's axi_hsci to the generated two-bank PHY (hsci_phy_2bank).
//  Outside this block you only see AXI4-Lite and the 8 LVDS pads.
//
//  The 11 PHY ports of hsci_master_top / axi_hsci and where they go:
//
//    axi_hsci port           direction source / destination in the PHY
//    ----------------------  --------  ------------------------------------
//    hsci_pclk               in        TX wizard pll0_clkout0
//    hsci_menc_clk[7:0]      out       TX wizard data_from_fabric_clk_out_p
//    hsci_mosi_data[7:0]     out       TX wizard data_from_fabric_data_out_p
//    hsci_miso_data[7:0]     in        RX wizard data_to_fabric_data_in_p
//    hsci_pll_reset          out       rst of BOTH wizards (active high)
//    hsci_pll_locked         in        pll0_locked TX & RX
//    hsci_rst_seq_done       in        rst_seq_done TX & RX
//    hsci_vtc_rdy_bsc_tx     in        vtc_rdy of all TX bitslice controls
//    hsci_dly_rdy_bsc_tx     in        dly_rdy of all TX bitslice controls
//    hsci_vtc_rdy_bsc_rx     in        vtc_rdy of the RX bitslice control
//    hsci_dly_rdy_bsc_rx     in        dly_rdy of the RX bitslice control
//
//  Bit reversal and gating miso_data on rst_seq_done live in
//  hsci_phy_2bank, just like in ADI's hsci_phy_top.sv.
// ***************************************************************************

`timescale 1ps/1ps

module hsci_top #(
  parameter S_AXI_ADDR_WIDTH = 18,   // 256K aperture: BRAM + regmap
  parameter AXI_DATA_WIDTH   = 32
) (
  // --- AXI4-Lite control ---------------------------------------------------
  input  wire                              s_axi_aclk,
  input  wire                              s_axi_aresetn,

  input  wire [S_AXI_ADDR_WIDTH-1:0]       s_axi_awaddr,
  input  wire [2:0]                        s_axi_awprot,
  input  wire                              s_axi_awvalid,
  output wire                              s_axi_awready,
  input  wire [AXI_DATA_WIDTH-1:0]         s_axi_wdata,
  input  wire [(AXI_DATA_WIDTH/8)-1:0]     s_axi_wstrb,
  input  wire                              s_axi_wvalid,
  output wire                              s_axi_wready,
  output wire [1:0]                        s_axi_bresp,
  output wire                              s_axi_bvalid,
  input  wire                              s_axi_bready,
  input  wire [S_AXI_ADDR_WIDTH-1:0]       s_axi_araddr,
  input  wire [2:0]                        s_axi_arprot,
  input  wire                              s_axi_arvalid,
  output wire                              s_axi_arready,
  output wire [AXI_DATA_WIDTH-1:0]         s_axi_rdata,
  output wire [1:0]                        s_axi_rresp,
  output wire                              s_axi_rvalid,
  input  wire                              s_axi_rready,

  // --- XPLL reference ------------------------------------------------------
  // Unbuffered 200 MHz. At ADI this comes from an axi_clkgen (MMCM) on
  // sys_cpu_clk; a dedicated oscillator on a GC pin is better jitter-wise.
  input  wire                              hsci_ref_clk,

  // --- LVDS pads to the MxFE -----------------------------------------------
  output wire                              hsci_ckin_p,   // FPGA -> MxFE clock
  output wire                              hsci_ckin_n,
  output wire                              hsci_din_p,    // FPGA -> MxFE MOSI
  output wire                              hsci_din_n,
  input  wire                              hsci_cko_p,    // MxFE -> FPGA strobe
  input  wire                              hsci_cko_n,
  input  wire                              hsci_do_p,     // MxFE -> FPGA MISO
  input  wire                              hsci_do_n,

  // --- debug / status ------------------------------------------------------
  output wire                              hsci_pclk_o,
  output wire                              hsci_pll_locked_o,
  output wire                              hsci_rst_seq_done_o
);

  // ---- the 11 signals between axi_hsci and the PHY -------------------------
  wire        pll_inclk;
  wire        hsci_pclk;
  wire [7:0]  hsci_menc_clk;
  wire [7:0]  hsci_mosi_data;
  wire [7:0]  hsci_miso_data;
  wire        hsci_pll_reset;
  wire        hsci_pll_locked;
  wire        hsci_rst_seq_done;
  wire        hsci_vtc_rdy_bsc_tx;
  wire        hsci_dly_rdy_bsc_tx;
  wire        hsci_vtc_rdy_bsc_rx;
  wire        hsci_dly_rdy_bsc_rx;

  assign hsci_pclk_o         = hsci_pclk;
  assign hsci_pll_locked_o   = hsci_pll_locked;
  assign hsci_rst_seq_done_o = hsci_rst_seq_done;

  // PLL0_CLK_SOURCE = BUFG_TO_PLL, so the reference must go through a BUFG.
  BUFG i_pll_inclk (
    .I (hsci_ref_clk),
    .O (pll_inclk));

  // ---- controller ----------------------------------------------------------
  axi_hsci #(
    .AXI_ADDR_WIDTH    (15),
    .AXI_DATA_WIDTH    (AXI_DATA_WIDTH),
    .REGMAP_ADDR_WIDTH (16),
    .S_AXI_ADDR_WIDTH  (S_AXI_ADDR_WIDTH)
  ) i_axi_hsci (
    .s_axi_aclk          (s_axi_aclk),
    .s_axi_aresetn       (s_axi_aresetn),
    .s_axi_awaddr        (s_axi_awaddr),
    .s_axi_awprot        (s_axi_awprot),
    .s_axi_awvalid       (s_axi_awvalid),
    .s_axi_awready       (s_axi_awready),
    .s_axi_wdata         (s_axi_wdata),
    .s_axi_wstrb         (s_axi_wstrb),
    .s_axi_wvalid        (s_axi_wvalid),
    .s_axi_wready        (s_axi_wready),
    .s_axi_bresp         (s_axi_bresp),
    .s_axi_bvalid        (s_axi_bvalid),
    .s_axi_bready        (s_axi_bready),
    .s_axi_araddr        (s_axi_araddr),
    .s_axi_arprot        (s_axi_arprot),
    .s_axi_arvalid       (s_axi_arvalid),
    .s_axi_arready       (s_axi_arready),
    .s_axi_rdata         (s_axi_rdata),
    .s_axi_rresp         (s_axi_rresp),
    .s_axi_rvalid        (s_axi_rvalid),
    .s_axi_rready        (s_axi_rready),

    .hsci_pclk           (hsci_pclk),
    .hsci_menc_clk       (hsci_menc_clk),
    .hsci_mosi_data      (hsci_mosi_data),
    .hsci_miso_data      (hsci_miso_data),

    .hsci_pll_reset      (hsci_pll_reset),
    .hsci_pll_locked     (hsci_pll_locked),
    .hsci_rst_seq_done   (hsci_rst_seq_done),
    .hsci_vtc_rdy_bsc_tx (hsci_vtc_rdy_bsc_tx),
    .hsci_dly_rdy_bsc_tx (hsci_dly_rdy_bsc_tx),
    .hsci_vtc_rdy_bsc_rx (hsci_vtc_rdy_bsc_rx),
    .hsci_dly_rdy_bsc_rx (hsci_dly_rdy_bsc_rx));

  // ---- PHY (generated by hsci_hssio_gen.tcl) -------------------------------
  hsci_phy_2bank i_hsci_phy (
    .pll_inclk        (pll_inclk),
    .hsci_pll_reset   (hsci_pll_reset),

    .hsci_pclk        (hsci_pclk),
    .hsci_pll_locked  (hsci_pll_locked),
    .rst_seq_done     (hsci_rst_seq_done),

    .hsci_mosi_clk_p  (hsci_ckin_p),
    .hsci_mosi_clk_n  (hsci_ckin_n),
    .hsci_mosi_d_p    (hsci_din_p),
    .hsci_mosi_d_n    (hsci_din_n),
    .hsci_miso_clk_p  (hsci_cko_p),
    .hsci_miso_clk_n  (hsci_cko_n),
    .hsci_miso_d_p    (hsci_do_p),
    .hsci_miso_d_n    (hsci_do_n),

    .hsci_menc_clk    (hsci_menc_clk),
    .hsci_mosi_data   (hsci_mosi_data),
    .hsci_miso_data   (hsci_miso_data),

    .vtc_rdy_bsc_tx   (hsci_vtc_rdy_bsc_tx),
    .dly_rdy_bsc_tx   (hsci_dly_rdy_bsc_tx),
    .vtc_rdy_bsc_rx   (hsci_vtc_rdy_bsc_rx),
    .dly_rdy_bsc_rx   (hsci_dly_rdy_bsc_rx));

endmodule