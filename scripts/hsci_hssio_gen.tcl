###############################################################################
##  hsci_hssio_gen.tcl
##
##  Generates for ADI's axi_hsci on UltraScale / UltraScale+ HP banks:
##    - two High Speed SelectIO Wizard instances (TX and RX, same or
##      different bank), fully derived from part + 8 package pins
##    - the RTL wrapper hsci_phy_2bank.sv with the correct bsc/fifo indices
##    - an XDC snippet with pin and clock constraints
##
##  Everything that can be derived is derived. Every impossible combination
##  fails hard with the reason and what to do about it.
##
##      vivado -mode batch -source hsci_hssio_gen.tcl
##
##  Set cfg(probe_only) to 1 to only analyse and see the predicted port map,
##  without creating IP.
###############################################################################

#=============================================================================
# 1. CONFIGURATION
#=============================================================================

set cfg(part)       "xczu17eg-ffvd1760-1-e"

# --- RX : MxFE -> FPGA ------------------------------------------------------
# rx_clk = hsci_cko (strobe), rx_dat = hsci_do (MISO)
set cfg(rx_clk_p)   "P37"
set cfg(rx_clk_n)   "N37"
set cfg(rx_dat_p)   "M36"
set cfg(rx_dat_n)   "L36"

# --- TX : FPGA -> MxFE ------------------------------------------------------
# tx_clk = hsci_ckin (forwarded clock), tx_dat = hsci_din (MOSI)
set cfg(tx_clk_p)   "V33"
set cfg(tx_clk_n)   "V34"
set cfg(tx_dat_p)   "Y34"
set cfg(tx_dat_n)   "W34"

# --- link -------------------------------------------------------------------
set cfg(data_speed) 1600        ;# Mb/s on the wire
set cfg(ref_freq)   200.000     ;# MHz reference into the XPLL
# NOTE: the wizard doesn't accept every reference frequency. The allowed
# values depend on data_speed (the PLL must reach it with its M/D
# combinations); 200 MHz is valid at 1600 Mb/s but NOT at 1250 -- there,
# 156.250 (= 1250/8) is the natural choice. Set an invalid value and the
# wizard error message names the complete list of valid ones.
set cfg(clk_source) "BUFG_TO_PLL"   ;# or a source from the bank (GC pin)

# A property of the slave (AD9084), not of the FPGA. ADI uses 3.
set cfg(rx_clk_to_data) 3

# --- overrides --------------------------------------------------------------
# Set to 1 if you have verified in the datasheet yourself that your speed
# grade reaches the requested rate and the table below is too conservative.
set cfg(force_rate) 0

# --- names / output ---------------------------------------------------------
set cfg(ip_tx)      "hsci_hssio_tx"
set cfg(ip_rx)      "hsci_hssio_rx"
set cfg(out_dir)    [file normalize [file dirname [info script]]]
set cfg(busdir_tx)  "0"   ;# TX_ONLY -- see the table below
set cfg(busdir_rx)  "1"   ;# RX_ONLY
set cfg(probe_only) 0

#-----------------------------------------------------------------------------
# CONFIG.BUS_DIR is an enum. The text labels are in the IP's component.xml
# (C:/Xilinx/<version>/Vivado/data/ip/xilinx/high_speed_selectio_wiz_v3_6):
#
#     0  TX_ONLY
#     1  RX_ONLY
#     3  TX + RX
#     2  BIDIR or TX+RX or TX+RX+BIDIR
#
# So 0 for our TX instance and 1 for the RX instance. That's not a detail:
# in a TX-only instance with BUS_DIR 3, the wizard silently locks
# PLL0_CLK_SOURCE to IBUF_TO_PLL and PLL0_INPUT_CLK_FREQ to data_speed/2 (and
# picks a clock pin in the bank itself). You then get an instance that
# expects an external 800 MHz clock on a bank pin instead of your 200 MHz
# fabric reference -- silently, because those properties are "disabled" in
# that mode and your set_property is ignored with only a WARNING. See
# hsci_verify_props.
#
# BUS_DIR 2 additionally clamps PLL0_DATA_SPEED to (800, 1300) Mb/s.
#-----------------------------------------------------------------------------

#-----------------------------------------------------------------------------
# The part/pin analysis, the rule checks, the port-map prediction and creating
# the wizard IPs live in hsci_hssio_lib.tcl, so the demo in demo/ uses the
# same engine. The MAX_RATE_HP_NATIVE table with the maximum LVDS rate per
# speed grade is there too.
#-----------------------------------------------------------------------------
source [file join [file dirname [info script]] hsci_hssio_lib.tcl]

#=============================================================================
# 7. MAIN
#=============================================================================

if {[llength [current_project -quiet]] == 0} {
    create_project -in_memory -part $cfg(part)
}

puts "\n===== DEVICE ===================================================="
set pi [hsci_part_info $cfg(part)]
set gen [hsci_check_arch $pi]
set we_linked [hsci_load_device $cfg(part)]
puts "  part        : [dict get $pi part]"
puts "  device      : [dict get $pi device]  package [dict get $pi package]"
puts "  architecture: [dict get $pi arch]  ($gen)"
puts "  speed grade : [dict get $pi speed]"
hsci_check_rate $pi $cfg(data_speed) $cfg(force_rate)

puts "\n===== PIN ANALYSIS =============================================="
set rxcp [hsci_pin_info $cfg(rx_clk_p)] ; set rxcn [hsci_pin_info $cfg(rx_clk_n)]
set rxdp [hsci_pin_info $cfg(rx_dat_p)] ; set rxdn [hsci_pin_info $cfg(rx_dat_n)]
set txcp [hsci_pin_info $cfg(tx_clk_p)] ; set txcn [hsci_pin_info $cfg(tx_clk_n)]
set txdp [hsci_pin_info $cfg(tx_dat_p)] ; set txdn [hsci_pin_info $cfg(tx_dat_n)]

puts "  RX strobe P : [hsci_fmt $rxcp]"
puts "  RX strobe N : [hsci_fmt $rxcn]"
puts "  RX data   P : [hsci_fmt $rxdp]"
puts "  RX data   N : [hsci_fmt $rxdn]"
puts "  TX clkfwd P : [hsci_fmt $txcp]"
puts "  TX clkfwd N : [hsci_fmt $txcn]"
puts "  TX data   P : [hsci_fmt $txdp]"
puts "  TX data   N : [hsci_fmt $txdn]"

puts "\n===== RULE CHECK ================================================"
hsci_check_pair "RX strobe" $rxcp $rxcn
hsci_check_pair "RX data"   $rxdp $rxdn
hsci_check_pair "TX clkfwd" $txcp $txcn
hsci_check_pair "TX data"   $txdp $txdn
puts "ok  four real differential pairs"

set rx_bank [dict get $rxcp bank]
set tx_bank [dict get $txcp bank]
hsci_check_bank_hp $rx_bank "RX"
hsci_check_bank_hp $tx_bank "TX"
puts "ok  bank $rx_bank (RX) and bank $tx_bank (TX) are HP banks"

if {[dict get $txdp bank] != $tx_bank} {
    hsci_fail "TX data is in bank [dict get $txdp bank] and the clkfwd in bank $tx_bank" \
              "both must be in the same byte group of the same bank"
}

set rx_bsc_list [hsci_check_rx_group $rxcp $rxdp]
puts "ok  RX strobe + data in byte group [dict get $rxcp byte] of bank $rx_bank"
puts "ok  RX strobe on [dict get $rxcp clkcap] pin (bsc [join $rx_bsc_list {, }])"
if {[llength $rx_bsc_list] > 1} {
    puts "    strobe in byte[dict get $rxcp byte][dict get $rxcp nibl], data in\
 byte[dict get $rxdp byte][dict get $rxdp nibl] -- two BITSLICE_CONTROLs"
}

if {[dict get $txcp byte] != [dict get $txdp byte]} {
    hsci_fail "TX clkfwd is in byte group [dict get $txcp byte] and the data in\
 [dict get $txdp byte]" \
              "both TX signals must share the same PLL clock in the byte group"
}
puts "ok  TX clkfwd + data in byte group [dict get $txcp byte]"

if {$rx_bank == $tx_bank} {
    hsci_warn "RX and TX in the same bank ($rx_bank). That works, but a single\
 wizard instance with a shared PLL (like ADI's vcu118) is more efficient."
}

# derived
set pclk_freq   [expr {double($cfg(data_speed)) / 8.0}]
set fwd_clk_mhz [expr {double($cfg(data_speed)) / 2.0}]
set fwd_clk_ns  [format %.3f [expr {1000.0 / $fwd_clk_mhz}]]
set tx_bsc_list [lsort -unique -integer [list [dict get $txcp bsc] [dict get $txdp bsc]]]
set tx_bytes    [lsort -unique -integer [list [dict get $txcp byte] [dict get $txdp byte]]]
set rx_bytes    [lsort -unique -integer [list [dict get $rxcp byte] [dict get $rxdp byte]]]
set rx_slice_d  [dict get $rxdp slice]
set rx_slice_c  [dict get $rxcp slice]

puts "\n===== DERIVED ==================================================="
puts "  data rate       : $cfg(data_speed) Mb/s"
puts "  hsci_pclk       : $pclk_freq MHz"
puts "  forwarded clock : $fwd_clk_mhz MHz (period $fwd_clk_ns ns)"
puts "  TX bank / bsc   : $tx_bank / [join $tx_bsc_list {, }]"
puts "  RX bank / bsc   : $rx_bank / [join $rx_bsc_list {, }]"
puts "  RX fifo slices  : data=$rx_slice_d strobe=$rx_slice_c"

set tx_ports [hsci_predict_tx $tx_bsc_list]
set rx_ports [hsci_predict_rx $rx_bsc_list $rx_slice_c $rx_slice_d]

puts "\n===== PREDICTED PORT MAP ========================================"
puts "  $cfg(ip_tx) ([llength $tx_ports]) : [join $tx_ports {, }]"
puts "  $cfg(ip_rx) ([llength $rx_ports]) : [join $rx_ports {, }]"

#-----------------------------------------------------------------------------
set common_props [list \
    CONFIG.DIFFERENTIAL_IO_STD  {LVDS} \
    CONFIG.ENABLE_N_PINS        {0} \
    CONFIG.APPEND_PIN_NO        {0} \
    CONFIG.ENABLE_PLL_DRP_PORTS {0} \
    CONFIG.RIU_FROM_PLL         {1} \
    CONFIG.PLL0_CLK_SOURCE      $cfg(clk_source) \
    CONFIG.PLL0_INPUT_CLK_FREQ  $cfg(ref_freq) \
    CONFIG.PLL0_DATA_SPEED      $cfg(data_speed) \
    CONFIG.PLL0_PLLOUT0         $pclk_freq]

set tx_props [concat $common_props \
    [list CONFIG.BANK "${tx_bank}_(HP)" CONFIG.BUS_DIR $cfg(busdir_tx) \
          CONFIG.TX_PRE_EMPHASIS_D {FALSE}] \
    [hsci_bytegroup_props $tx_bank $tx_bytes] \
    [hsci_pin_props [dict get $txdp byte] [dict get $txdp idx] {data_out_p} {}        {TX} {} ] \
    [hsci_pin_props [dict get $txdn byte] [dict get $txdn idx] {data_out_n} {}        {TX} {1}] \
    [hsci_pin_props [dict get $txcp byte] [dict get $txcp idx] {clk_out_p}  {Clk Fwd} {TX} {} ] \
    [hsci_pin_props [dict get $txcn byte] [dict get $txcn idx] {clk_out_n}  {Clk Fwd} {TX} {1}]]

set rx_props [concat $common_props \
    [list CONFIG.BANK "${rx_bank}_(HP)" CONFIG.BUS_DIR $cfg(busdir_rx) \
          CONFIG.FIFO_RD_EN_CONTROL {1} \
          CONFIG.PLL0_RX_EXTERNAL_CLK_TO_DATA $cfg(rx_clk_to_data)] \
    [hsci_bytegroup_props $rx_bank $rx_bytes] \
    [hsci_pin_props [dict get $rxcp byte] [dict get $rxcp idx] {clk_in_p}  {Strobe}] \
    [hsci_pin_props [dict get $rxcn byte] [dict get $rxcn idx] {clk_in_n}  {Strobe}] \
    [hsci_pin_props [dict get $rxdp byte] [dict get $rxdp idx] {data_in_p} {Data}] \
    [hsci_pin_props [dict get $rxdn byte] [dict get $rxdn idx] {data_in_n} {Data}]]

# All device queries are done now and cached in tx_props/rx_props; the
# temporary design can go away before we start creating IP.
#
# NOTE: link_design sets DESIGN_MODE to GateLvl, and close_design does NOT
# set it back. create_ip then refuses with "IP commands are only valid for
# RTL projects". Hence the explicit restore.
if {$we_linked} {
    catch {close_design}
    set fs [get_filesets -quiet sources_1]
    if {$fs ne "" && [get_property -quiet DESIGN_MODE $fs] ne "RTL"} {
        set_property DESIGN_MODE RTL $fs
        puts "  DESIGN_MODE restored to RTL after link_design"
    }
}

if {$cfg(probe_only)} {
    puts "\nprobe_only=1 -- analysis done, no IP created.\n"
    return
}

puts "\n===== GENERATING IP ============================================="
set tx_keep [list "[dict get $txdp byte],[dict get $txdp idx]" "[dict get $txdn byte],[dict get $txdn idx]"                   "[dict get $txcp byte],[dict get $txcp idx]" "[dict get $txcn byte],[dict get $txcn idx]"]
set ip_tx [hsci_create_ip $cfg(ip_tx) $tx_props $tx_keep]
puts "  TX : $cfg(ip_tx)  wizard [lindex [split [get_property IPDEF $ip_tx] :] 3]  bank $tx_bank"
set rx_keep [list "[dict get $rxcp byte],[dict get $rxcp idx]" "[dict get $rxcn byte],[dict get $rxcn idx]"                   "[dict get $rxdp byte],[dict get $rxdp idx]" "[dict get $rxdn byte],[dict get $rxdn idx]"]
set ip_rx [hsci_create_ip $cfg(ip_rx) $rx_props $rx_keep]
puts "  RX : $cfg(ip_rx)  wizard [lindex [split [get_property IPDEF $ip_rx] :] 3]  bank $rx_bank"

foreach ip [list $cfg(ip_tx) $cfg(ip_rx)] {
    generate_target {instantiation_template} [get_files ${ip}.xci]
    generate_target all                      [get_files ${ip}.xci]
}

puts "\n===== PORT CHECK ================================================"
set ok_tx [hsci_check_ports $cfg(ip_tx) $tx_ports]
set ok_rx [hsci_check_ports $cfg(ip_rx) $rx_ports]
if {!$ok_tx || !$ok_rx} {
    puts "\n  hsci_phy_2bank.sv will NOT elaborate as it is."
    puts "  Report the \"wizard offers\" line above and the template gets fixed."
}

#=============================================================================
# 8. WRAPPER
#=============================================================================

set tmpl {// GENERATED by hsci_hssio_gen.tcl -- do not edit by hand.
//   part      : @PART@   (speed grade @SPEED@)
//   data rate : @RATE@ Mb/s   ->  hsci_pclk = @PCLK@ MHz
//   TX        : bank @TXBANK@, byte group @TXBYTE@, bsc @TXBSCS@
//   RX        : bank @RXBANK@, byte @RXBYTE@@RXNIB@, bsc @RXBSCS@,
//               fifo slice data=@SLICED@ strobe=@SLICEC@
`timescale 1ps/1ps

module hsci_phy_2bank (
  input  wire        pll_inclk,        // @REF@ MHz, via BUFG
  input  wire        hsci_pll_reset,   // from axi_hsci, active high

  output logic       hsci_pclk,        // TX PLL clkout0 = @PCLK@ MHz
  output logic       hsci_pll_locked,
  output logic       rst_seq_done,

  // TX pads (FPGA -> MxFE)
  output logic       hsci_mosi_d_p,
  output logic       hsci_mosi_d_n,
  output logic       hsci_mosi_clk_p,
  output logic       hsci_mosi_clk_n,
  // RX pads (MxFE -> FPGA)
  input  wire        hsci_miso_d_p,
  input  wire        hsci_miso_d_n,
  input  wire        hsci_miso_clk_p,
  input  wire        hsci_miso_clk_n,

  // fabric side, towards hsci_master_top
  input  wire  [7:0] hsci_menc_clk,
  input  wire  [7:0] hsci_mosi_data,
  output logic [7:0] hsci_miso_data,

  output logic       vtc_rdy_bsc_tx,
  output logic       dly_rdy_bsc_tx,
  output logic       vtc_rdy_bsc_rx,
  output logic       dly_rdy_bsc_rx
);

  logic [7:0] mosi_data_br, menc_clk_br, miso_data_br, miso_clk_br;
  logic       locked_tx, locked_rx;
  logic       seq_done_tx, seq_done_rx;
  logic       fifo_empty_dat, fifo_empty_str;
  logic       rx_pclk_unused;
@TXDECL@@RXDECL@

  // Reverse the bit order between axi_hsci and the serializer (like ADI).
  assign mosi_data_br = {hsci_mosi_data[0], hsci_mosi_data[1], hsci_mosi_data[2], hsci_mosi_data[3],
                         hsci_mosi_data[4], hsci_mosi_data[5], hsci_mosi_data[6], hsci_mosi_data[7]};
  assign menc_clk_br  = {hsci_menc_clk[0],  hsci_menc_clk[1],  hsci_menc_clk[2],  hsci_menc_clk[3],
                         hsci_menc_clk[4],  hsci_menc_clk[5],  hsci_menc_clk[6],  hsci_menc_clk[7]};

  assign hsci_miso_data = rst_seq_done
      ? {miso_data_br[0], miso_data_br[1], miso_data_br[2], miso_data_br[3],
         miso_data_br[4], miso_data_br[5], miso_data_br[6], miso_data_br[7]}
      : 8'h00;

  // axi_hsci wants a combined view across both banks
  assign hsci_pll_locked = locked_tx   & locked_rx;
  assign rst_seq_done    = seq_done_tx & seq_done_rx;
  assign dly_rdy_bsc_tx  = @TXDLY@;
  assign vtc_rdy_bsc_tx  = @TXVTC@;
  assign dly_rdy_bsc_rx  = @RXDLY@;
  assign vtc_rdy_bsc_rx  = @RXVTC@;

  //------------------------------------------------------------------ TX ---
  @IPTX@ i_hssio_tx (
    .clk                         (pll_inclk),
    .rst                         (hsci_pll_reset),
    .pll0_locked                 (locked_tx),
    .pll0_clkout0                (hsci_pclk),
    .rst_seq_done                (seq_done_tx),
@TXCONN@    .data_out_p                  (hsci_mosi_d_p),
    .data_out_n                  (hsci_mosi_d_n),
    .data_from_fabric_data_out_p (mosi_data_br),
    .clk_out_p                   (hsci_mosi_clk_p),
    .clk_out_n                   (hsci_mosi_clk_n),
    .data_from_fabric_clk_out_p  (menc_clk_br));

  //------------------------------------------------------------------ RX ---
  // fifo_rd_clk comes from the TX PLL: the MxFE derives hsci_cko from our
  // hsci_ckin, so the write and read side of the bitslice FIFO are mesochronous.
  // The FIFO only absorbs the round-trip phase -- not a real CDC.
  @IPRX@ i_hssio_rx (
    .clk                         (pll_inclk),
    .rst                         (hsci_pll_reset),
    .pll0_locked                 (locked_rx),
    .pll0_clkout0                (rx_pclk_unused),
    .rst_seq_done                (seq_done_rx),
@RXCONN@    .clk_in_p                    (hsci_miso_clk_p),
    .clk_in_n                    (hsci_miso_clk_n),
    .data_to_fabric_clk_in_p     (miso_clk_br),
    .data_in_p                   (hsci_miso_d_p),
    .data_in_n                   (hsci_miso_d_n),
    .data_to_fabric_data_in_p    (miso_data_br),
@FIFOCONN@

endmodule
}

set tx_decl ""
set tx_conn ""
foreach b $tx_bsc_list {
    append tx_decl "  logic       tx_dly_rdy_bsc${b}, tx_vtc_rdy_bsc${b};\n"
    append tx_conn "    .dly_rdy_bsc${b}                (tx_dly_rdy_bsc${b}),\n"
    append tx_conn "    .vtc_rdy_bsc${b}                (tx_vtc_rdy_bsc${b}),\n"
    append tx_conn "    .en_vtc_bsc${b}                 (1'b1),\n"
}

set fifo_conn ""
append fifo_conn [format "    %-28s (hsci_pclk),\n"      ".fifo_rd_clk_$rx_slice_c"]
append fifo_conn [format "    %-28s (1'b0),\n"           ".fifo_rd_en_$rx_slice_c"]
append fifo_conn [format "    %-28s (fifo_empty_str),\n" ".fifo_empty_$rx_slice_c"]
append fifo_conn [format "    %-28s (hsci_pclk),\n"      ".fifo_rd_clk_$rx_slice_d"]
append fifo_conn [format "    %-28s (!fifo_empty_dat & rst_seq_done),\n" ".fifo_rd_en_$rx_slice_d"]
append fifo_conn [format "    %-28s (fifo_empty_dat));"  ".fifo_empty_$rx_slice_d"]

# The RX side can, like the TX side, have more than one BITSLICE_CONTROL: that
# happens as soon as the strobe is in the other nibble of the byte group than
# the data (allowed, because a DBC pin clocks both nibbles).
set rx_decl ""
set rx_conn ""
foreach b $rx_bsc_list {
    append rx_decl "  logic       rx_dly_rdy_bsc${b}, rx_vtc_rdy_bsc${b};\n"
    append rx_conn "    .dly_rdy_bsc${b}                (rx_dly_rdy_bsc${b}),\n"
    append rx_conn "    .vtc_rdy_bsc${b}                (rx_vtc_rdy_bsc${b}),\n"
    append rx_conn "    .en_vtc_bsc${b}                 (1'b1),\n"
}

set tx_dly [list] ; set tx_vtc [list]
foreach b $tx_bsc_list {
    lappend tx_dly "tx_dly_rdy_bsc${b}" ; lappend tx_vtc "tx_vtc_rdy_bsc${b}"
}
# strip the trailing newline: the template already puts one behind it
set rx_decl [string trimright $rx_decl "\n"]

set rx_dly [list] ; set rx_vtc [list]
foreach b $rx_bsc_list {
    lappend rx_dly "rx_dly_rdy_bsc${b}" ; lappend rx_vtc "rx_vtc_rdy_bsc${b}"
}

set out [string map [list \
    @PART@   $cfg(part)              @RATE@   $cfg(data_speed) \
    @SPEED@  [dict get $pi speed]    @REF@    $cfg(ref_freq)   \
    @PCLK@   $pclk_freq                                        \
    @IPTX@   $cfg(ip_tx)             @IPRX@   $cfg(ip_rx)      \
    @TXBANK@ $tx_bank                @RXBANK@ $rx_bank         \
    @TXBYTE@ [dict get $txdp byte]   @RXBYTE@ [dict get $rxdp byte] \
    @RXNIB@  [dict get $rxdp nibl]                             \
    @TXBSCS@ [join $tx_bsc_list ", "] @RXBSCS@ [join $rx_bsc_list ", "] \
    @SLICED@ $rx_slice_d             @SLICEC@ $rx_slice_c      \
    @TXDECL@ $tx_decl                @TXCONN@ $tx_conn         \
    @RXDECL@ $rx_decl                @RXCONN@ $rx_conn         \
    @FIFOCONN@ $fifo_conn                                      \
    @TXDLY@  [join $tx_dly " & "]    @TXVTC@  [join $tx_vtc " & "] \
    @RXDLY@  [join $rx_dly " & "]    @RXVTC@  [join $rx_vtc " & "] \
    ] $tmpl]

set path [file join $cfg(out_dir) hsci_phy_2bank.sv]
set fh [open $path w] ; puts -nonewline $fh $out ; close $fh
puts "\n  written: $path"

#=============================================================================
# 9. XDC
#=============================================================================

set xdc_tmpl {# GENERATED by hsci_hssio_gen.tcl
# part @PART@, @RATE@ Mb/s
# LVDS in HP banks requires VCCO = 1.8V on bank @TXBANK@ (TX) and bank @RXBANK@ (RX).

# --- TX : FPGA -> MxFE ---
set_property -dict {PACKAGE_PIN @TXCP@ IOSTANDARD LVDS} [get_ports hsci_ckin_p] ; # @TXCPF@
set_property -dict {PACKAGE_PIN @TXCN@ IOSTANDARD LVDS} [get_ports hsci_ckin_n] ; # @TXCNF@
set_property -dict {PACKAGE_PIN @TXDP@ IOSTANDARD LVDS} [get_ports hsci_din_p]  ; # @TXDPF@
set_property -dict {PACKAGE_PIN @TXDN@ IOSTANDARD LVDS} [get_ports hsci_din_n]  ; # @TXDNF@

# --- RX : MxFE -> FPGA ---
set_property -dict {PACKAGE_PIN @RXCP@ IOSTANDARD LVDS DIFF_TERM_ADV TERM_100} [get_ports hsci_cko_p] ; # @RXCPF@
set_property -dict {PACKAGE_PIN @RXCN@ IOSTANDARD LVDS DIFF_TERM_ADV TERM_100} [get_ports hsci_cko_n] ; # @RXCNF@
set_property -dict {PACKAGE_PIN @RXDP@ IOSTANDARD LVDS DIFF_TERM_ADV TERM_100} [get_ports hsci_do_p]  ; # @RXDPF@
set_property -dict {PACKAGE_PIN @RXDN@ IOSTANDARD LVDS DIFF_TERM_ADV TERM_100} [get_ports hsci_do_n]  ; # @RXDNF@

# Forwarded clock back from the MxFE: @FWDMHZ@ MHz
create_clock -name hsci_cko -period @FWDNS@ [get_ports hsci_cko_p]
}

set xdc [string map [list \
    @PART@ $cfg(part) @RATE@ $cfg(data_speed) \
    @TXBANK@ $tx_bank @RXBANK@ $rx_bank \
    @TXCP@ [dict get $txcp pin] @TXCPF@ [dict get $txcp func] \
    @TXCN@ [dict get $txcn pin] @TXCNF@ [dict get $txcn func] \
    @TXDP@ [dict get $txdp pin] @TXDPF@ [dict get $txdp func] \
    @TXDN@ [dict get $txdn pin] @TXDNF@ [dict get $txdn func] \
    @RXCP@ [dict get $rxcp pin] @RXCPF@ [dict get $rxcp func] \
    @RXCN@ [dict get $rxcn pin] @RXCNF@ [dict get $rxcn func] \
    @RXDP@ [dict get $rxdp pin] @RXDPF@ [dict get $rxdp func] \
    @RXDN@ [dict get $rxdn pin] @RXDNF@ [dict get $rxdn func] \
    @FWDMHZ@ $fwd_clk_mhz @FWDNS@ $fwd_clk_ns \
    ] $xdc_tmpl]

set path [file join $cfg(out_dir) hsci_phy_pins.xdc]
set fh [open $path w] ; puts -nonewline $fh $xdc ; close $fh
puts "  written: $path"

puts "\n===== DONE ======================================================\n"