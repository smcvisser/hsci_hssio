###############################################################################
##  hsci_hssio_gen.tcl
##
##  Genereert voor ADI's axi_hsci op UltraScale / UltraScale+ HP banks:
##    - twee High Speed SelectIO Wizard instanties (TX en RX, zelfde of
##      verschillende bank), volledig afgeleid uit part + 8 package pins
##    - de RTL-wrapper hsci_phy_2bank.sv met de juiste bsc-/fifo-indices
##    - een XDC-snippet met pin- en clock-constraints
##
##  Alles wat afgeleid kan worden wordt afgeleid. Elke onmogelijke combinatie
##  geeft een harde fout met de reden en wat je eraan moet doen.
##
##      vivado -mode batch -source hsci_hssio_gen.tcl
##
##  Zet cfg(probe_only) op 1 om alleen te analyseren en de voorspelde port map
##  te zien, zonder IP aan te maken.
###############################################################################

#=============================================================================
# 1. CONFIGURATIE
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
set cfg(data_speed) 1600        ;# Mb/s op de draad
set cfg(ref_freq)   200.000     ;# MHz referentie naar de XPLL
# LET OP: de wizard accepteert niet elke referentiefrequentie. De toegestane
# waarden hangen af van data_speed (de PLL moet er met haar M/D-combinaties op
# uitkomen); 200 MHz is geldig bij 1600 Mb/s, maar NIET bij 1250 -- daar is
# 156.250 (= 1250/8) de natuurlijke keuze. Zet je een ongeldige waarde, dan
# noemt de wizard-foutmelding de complete lijst geldige waarden.
set cfg(clk_source) "BUFG_TO_PLL"   ;# of een bron uit de bank (GC pin)

# Kenmerk van de slave (AD9084), niet van de FPGA. ADI gebruikt 3.
set cfg(rx_clk_to_data) 3

# --- overrides --------------------------------------------------------------
# Zet op 1 als je zelf in de datasheet hebt geverifieerd dat je speed grade
# de gevraagde rate haalt en de tabel hieronder te conservatief is.
set cfg(force_rate) 0

# --- namen / output ---------------------------------------------------------
set cfg(ip_tx)      "hsci_hssio_tx"
set cfg(ip_rx)      "hsci_hssio_rx"
set cfg(out_dir)    [file normalize [file dirname [info script]]]
set cfg(busdir_tx)  "0"   ;# TX_ONLY -- zie de tabel hieronder
set cfg(busdir_rx)  "1"   ;# RX_ONLY
set cfg(probe_only) 0

#-----------------------------------------------------------------------------
# CONFIG.BUS_DIR is een enum. De tekstlabels staan in component.xml van het IP
# (C:/Xilinx/<versie>/Vivado/data/ip/xilinx/high_speed_selectio_wiz_v3_6):
#
#     0  TX_ONLY
#     1  RX_ONLY
#     3  TX + RX
#     2  BIDIR of TX+RX of TX+RX+BIDIR
#
# Dus 0 voor onze TX-instantie en 1 voor de RX-instantie. Dat is geen detail:
# in een TX-only instantie met BUS_DIR 3 zet de wizard PLL0_CLK_SOURCE vast op
# IBUF_TO_PLL en PLL0_INPUT_CLK_FREQ op data_speed/2 (en kiest zelf een
# klokpin in de bank). Je krijgt dan een instantie die een externe 800 MHz
# klok op een bankpin verwacht in plaats van je 200 MHz fabric-referentie --
# stilzwijgend, want die properties zijn in die modus "disabled" en je
# set_property wordt genegeerd met alleen een WARNING. Zie hsci_verify_props.
#
# BUS_DIR 2 klemt bovendien PLL0_DATA_SPEED op (800, 1300) Mb/s.
#-----------------------------------------------------------------------------

#-----------------------------------------------------------------------------
# De part-/pin-analyse, de regelchecks, de port-map-voorspelling en het
# aanmaken van de wizard-IPs staan in hsci_hssio_lib.tcl, zodat de demo in
# demo/ dezelfde motor gebruikt. Daar staat ook de tabel MAX_RATE_HP_NATIVE
# met de maximale LVDS-rate per speed grade.
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
puts "  architectuur: [dict get $pi arch]  ($gen)"
puts "  speed grade : [dict get $pi speed]"
hsci_check_rate $pi $cfg(data_speed) $cfg(force_rate)

puts "\n===== PIN-ANALYSE ==============================================="
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

puts "\n===== REGELCHECK ================================================"
hsci_check_pair "RX strobe" $rxcp $rxcn
hsci_check_pair "RX data"   $rxdp $rxdn
hsci_check_pair "TX clkfwd" $txcp $txcn
hsci_check_pair "TX data"   $txdp $txdn
puts "ok  vier echte differentiele paren"

set rx_bank [dict get $rxcp bank]
set tx_bank [dict get $txcp bank]
hsci_check_bank_hp $rx_bank "RX"
hsci_check_bank_hp $tx_bank "TX"
puts "ok  bank $rx_bank (RX) en bank $tx_bank (TX) zijn HP banks"

if {[dict get $txdp bank] != $tx_bank} {
    hsci_fail "TX data zit in bank [dict get $txdp bank] en de clkfwd in bank $tx_bank" \
              "beide moeten in dezelfde byte group van dezelfde bank"
}

set rx_bsc_list [hsci_check_rx_group $rxcp $rxdp]
puts "ok  RX strobe + data in byte group [dict get $rxcp byte] van bank $rx_bank"
puts "ok  RX strobe op [dict get $rxcp clkcap] pin (bsc [join $rx_bsc_list {, }])"
if {[llength $rx_bsc_list] > 1} {
    puts "    strobe in byte[dict get $rxcp byte][dict get $rxcp nibl], data in\
 byte[dict get $rxdp byte][dict get $rxdp nibl] -- twee BITSLICE_CONTROLs"
}

if {[dict get $txcp byte] != [dict get $txdp byte]} {
    hsci_fail "TX clkfwd zit in byte group [dict get $txcp byte] en de data in\
 [dict get $txdp byte]" \
              "beide TX-signalen moeten dezelfde PLL-klok in de byte group delen"
}
puts "ok  TX clkfwd + data in byte group [dict get $txcp byte]"

if {$rx_bank == $tx_bank} {
    hsci_warn "RX en TX in dezelfde bank ($rx_bank). Dat werkt, maar een enkele\
 wizard-instantie met gedeelde PLL (zoals ADI's vcu118) is efficienter."
}

# afgeleid
set pclk_freq   [expr {double($cfg(data_speed)) / 8.0}]
set fwd_clk_mhz [expr {double($cfg(data_speed)) / 2.0}]
set fwd_clk_ns  [format %.3f [expr {1000.0 / $fwd_clk_mhz}]]
set tx_bsc_list [lsort -unique -integer [list [dict get $txcp bsc] [dict get $txdp bsc]]]
set tx_bytes    [lsort -unique -integer [list [dict get $txcp byte] [dict get $txdp byte]]]
set rx_bytes    [lsort -unique -integer [list [dict get $rxcp byte] [dict get $rxdp byte]]]
set rx_slice_d  [dict get $rxdp slice]
set rx_slice_c  [dict get $rxcp slice]

puts "\n===== AFGELEID =================================================="
puts "  data rate       : $cfg(data_speed) Mb/s"
puts "  hsci_pclk       : $pclk_freq MHz"
puts "  forwarded clock : $fwd_clk_mhz MHz (periode $fwd_clk_ns ns)"
puts "  TX bank / bsc   : $tx_bank / [join $tx_bsc_list {, }]"
puts "  RX bank / bsc   : $rx_bank / [join $rx_bsc_list {, }]"
puts "  RX fifo slices  : data=$rx_slice_d strobe=$rx_slice_c"

set tx_ports [hsci_predict_tx $tx_bsc_list]
set rx_ports [hsci_predict_rx $rx_bsc_list $rx_slice_c $rx_slice_d]

puts "\n===== VOORSPELDE PORT MAP ======================================="
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

# Alle device-queries zijn nu gedaan en gecached in tx_props/rx_props; het
# tijdelijke design mag weg voordat we IP gaan aanmaken.
#
# LET OP: link_design zet DESIGN_MODE op GateLvl, en close_design zet dat NIET
# terug. create_ip weigert dan met "IP commands are only valid for RTL
# projects". Vandaar het expliciete herstel.
if {$we_linked} {
    catch {close_design}
    set fs [get_filesets -quiet sources_1]
    if {$fs ne "" && [get_property -quiet DESIGN_MODE $fs] ne "RTL"} {
        set_property DESIGN_MODE RTL $fs
        puts "  DESIGN_MODE hersteld naar RTL na link_design"
    }
}

if {$cfg(probe_only)} {
    puts "\nprobe_only=1 -- analyse klaar, geen IP aangemaakt.\n"
    return
}

puts "\n===== IP GENEREREN =============================================="
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

puts "\n===== POORTCHECK ================================================"
set ok_tx [hsci_check_ports $cfg(ip_tx) $tx_ports]
set ok_rx [hsci_check_ports $cfg(ip_rx) $rx_ports]
if {!$ok_tx || !$ok_rx} {
    puts "\n  hsci_phy_2bank.sv gaat NIET elaboreren zoals hij is."
    puts "  Meld de \"wizard biedt\"-regel hierboven en het template wordt aangepast."
}

#=============================================================================
# 8. WRAPPER
#=============================================================================

set tmpl {// GEGENEREERD door hsci_hssio_gen.tcl -- niet met de hand aanpassen.
//   part      : @PART@   (speed grade @SPEED@)
//   data rate : @RATE@ Mb/s   ->  hsci_pclk = @PCLK@ MHz
//   TX        : bank @TXBANK@, byte group @TXBYTE@, bsc @TXBSCS@
//   RX        : bank @RXBANK@, byte @RXBYTE@@RXNIB@, bsc @RXBSCS@,
//               fifo slice data=@SLICED@ strobe=@SLICEC@
`timescale 1ps/1ps

module hsci_phy_2bank (
  input  wire        pll_inclk,        // @REF@ MHz, via BUFG
  input  wire        hsci_pll_reset,   // van axi_hsci, actief hoog

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

  // fabric kant, richting hsci_master_top
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

  // Bitvolgorde omdraaien tussen axi_hsci en de serializer (zoals ADI).
  assign mosi_data_br = {hsci_mosi_data[0], hsci_mosi_data[1], hsci_mosi_data[2], hsci_mosi_data[3],
                         hsci_mosi_data[4], hsci_mosi_data[5], hsci_mosi_data[6], hsci_mosi_data[7]};
  assign menc_clk_br  = {hsci_menc_clk[0],  hsci_menc_clk[1],  hsci_menc_clk[2],  hsci_menc_clk[3],
                         hsci_menc_clk[4],  hsci_menc_clk[5],  hsci_menc_clk[6],  hsci_menc_clk[7]};

  assign hsci_miso_data = rst_seq_done
      ? {miso_data_br[0], miso_data_br[1], miso_data_br[2], miso_data_br[3],
         miso_data_br[4], miso_data_br[5], miso_data_br[6], miso_data_br[7]}
      : 8'h00;

  // axi_hsci wil een gecombineerd beeld over beide banks
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
  // fifo_rd_clk komt van de TX PLL: de MxFE leidt hsci_cko af van onze
  // hsci_ckin, dus schrijf- en leeszijde van de bitslice-FIFO zijn mesochroon.
  // De FIFO vangt alleen de round-trip fase op -- geen echte CDC.
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

# De RX-kant kan net als de TX-kant meer dan een BITSLICE_CONTROL hebben: dat
# gebeurt zodra de strobe in de andere nibble van de byte group zit dan de data
# (mag, want een DBC-pin klokt beide nibbles).
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
# de laatste newline weg: de template zet er zelf al een achter
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
puts "\n  geschreven: $path"

#=============================================================================
# 9. XDC
#=============================================================================

set xdc_tmpl {# GEGENEREERD door hsci_hssio_gen.tcl
# part @PART@, @RATE@ Mb/s
# LVDS in HP banks vereist VCCO = 1.8V op bank @TXBANK@ (TX) en bank @RXBANK@ (RX).

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

# Forwarded clock terug van de MxFE: @FWDMHZ@ MHz
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
puts "  geschreven: $path"

puts "\n===== KLAAR =====================================================\n"
