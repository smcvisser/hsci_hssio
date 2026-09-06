###############################################################################
##  hsci_demo_gen.tcl
##
##  De Vivado-helft van de demo. Wordt aangeroepen door demo/build_demo.py en
##  doet alles waarvoor je de device database nodig hebt:
##
##    1. de acht HSCI-pinnen analyseren en de regels toetsen
##    2. de twee High Speed SelectIO Wizard instanties aanmaken
##       (afgeleid uit de pinnen, niet overgetypt uit docs/hssio_for_demo.txt)
##    3. de MMCM, de JTAG-AXI master en de AXI-Lite klokconverter aanmaken
##    4. de voorspelde port map toetsen aan de echte .veo
##    5. alles wat de templates nodig hebben wegschrijven als JSON
##
##  De analyse en de wizard-helpers komen uit scripts/hsci_hssio_lib.tcl, zodat
##  de demo en de generator dezelfde motor gebruiken.
##
##      vivado -mode batch -source hsci_demo_gen.tcl -tclargs <cfg.tcl> <out.json>
###############################################################################

set cfg_file  [lindex $argv 0]
set json_file [lindex $argv 1]
set here      [file normalize [file dirname [info script]]]

source [file join $here .. .. scripts hsci_hssio_lib.tcl]
source $cfg_file      ;# vult de array demo(...)

proc j_str  {k v} { return "\"$k\": \"$v\"" }
proc j_num  {k v} { return "\"$k\": $v" }
proc j_bool {k v} { return "\"$k\": [expr {$v ? "true" : "false"}]" }
proc j_list {k l} {
    set parts [list]
    foreach e $l { lappend parts "\"$e\"" }
    return "\"$k\": \[[join $parts {, }]\]"
}
proc j_ilist {k l} { return "\"$k\": \[[join $l {, }]\]" }
proc j_obj  {parts {indent "    "}} {
    return "\{\n$indent[join $parts ",\n$indent"]\n[string range $indent 2 end]\}"
}

#=============================================================================
# 1. DEVICE EN PINNEN
#=============================================================================

create_project -in_memory -part $demo(part)

puts "\n===== DEVICE ===================================================="
set pi  [hsci_part_info $demo(part)]
set gen [hsci_check_arch $pi]
set we_linked [hsci_load_device $demo(part)]
puts "  part        : [dict get $pi part]"
puts "  device      : [dict get $pi device]  package [dict get $pi package]"
puts "  speed grade : [dict get $pi speed]  ($gen)"
hsci_check_rate $pi $demo(data_speed) $demo(force_rate)

puts "\n===== PIN-ANALYSE ==============================================="
set txcp [hsci_pin_info $demo(tx_clk_p)] ; set txcn [hsci_pin_info $demo(tx_clk_n)]
set txdp [hsci_pin_info $demo(tx_dat_p)] ; set txdn [hsci_pin_info $demo(tx_dat_n)]
set rxcp [hsci_pin_info $demo(rx_clk_p)] ; set rxcn [hsci_pin_info $demo(rx_clk_n)]
set rxdp [hsci_pin_info $demo(rx_dat_p)] ; set rxdn [hsci_pin_info $demo(rx_dat_n)]

foreach {label d} [list "TX clkfwd P" $txcp "TX clkfwd N" $txcn \
                        "TX data   P" $txdp "TX data   N" $txdn \
                        "RX strobe P" $rxcp "RX strobe N" $rxcn \
                        "RX data   P" $rxdp "RX data   N" $rxdn] {
    puts "  $label : [hsci_fmt $d]"
}

puts "\n===== REGELCHECK ================================================"
hsci_check_pair "TX clkfwd" $txcp $txcn
hsci_check_pair "TX data"   $txdp $txdn
hsci_check_pair "RX strobe" $rxcp $rxcn
hsci_check_pair "RX data"   $rxdp $rxdn
puts "ok  vier echte differentiele paren"

set tx_bank [dict get $txcp bank]
set rx_bank [dict get $rxcp bank]
hsci_check_bank_hp $tx_bank "TX"
hsci_check_bank_hp $rx_bank "RX"
puts "ok  bank $tx_bank (TX) en bank $rx_bank (RX) zijn HP banks"

if {[dict get $txdp bank] != $tx_bank || [dict get $txcp byte] != [dict get $txdp byte]} {
    hsci_fail "TX clkfwd en data zitten niet in dezelfde byte group" \
              "beide TX-signalen delen de PLL-klok van hun byte group"
}
set tx_bsc_list [lsort -unique -integer [list [dict get $txcp bsc] [dict get $txdp bsc]]]
puts "ok  TX clkfwd + data in byte group [dict get $txcp byte] (bsc [join $tx_bsc_list {, }])"

set rx_bsc_list [hsci_check_rx_group $rxcp $rxdp]
puts "ok  RX strobe op [dict get $rxcp clkcap] pin, byte group [dict get $rxcp byte]\
 (bsc [join $rx_bsc_list {, }])"

#=============================================================================
# 2. AFGELEIDE GETALLEN
#=============================================================================

set pclk_freq   [expr {double($demo(data_speed)) / 8.0}]
set fwd_clk_mhz [expr {double($demo(data_speed)) / 2.0}]
set tx_bytes    [lsort -unique -integer [list [dict get $txcp byte] [dict get $txdp byte]]]
set rx_bytes    [lsort -unique -integer [list [dict get $rxcp byte] [dict get $rxdp byte]]]
set rx_slice_c  [dict get $rxcp slice]
set rx_slice_d  [dict get $rxdp slice]

puts "\n===== AFGELEID =================================================="
puts "  data rate       : $demo(data_speed) Mb/s"
puts "  hsci_pclk       : $pclk_freq MHz"
puts "  forwarded clock : $fwd_clk_mhz MHz"
puts "  RX fifo slices  : strobe=$rx_slice_c data=$rx_slice_d"

set tx_ports [hsci_predict_tx $tx_bsc_list \
    $demo(tx_sig_dat_p) $demo(tx_sig_dat_n) $demo(tx_sig_clk_p) $demo(tx_sig_clk_n)]
set rx_ports [hsci_predict_rx $rx_bsc_list $rx_slice_c $rx_slice_d \
    $demo(rx_sig_clk_p) $demo(rx_sig_clk_n) $demo(rx_sig_dat_p) $demo(rx_sig_dat_n)]

#=============================================================================
# 3. WIZARD-PROPERTIES
#
#  Zelfde vorm als docs/hssio_for_demo.txt, maar afgeleid uit de pinnen:
#  BANK, BYTE?_PIN? en de bsc-indices komen allemaal uit de device database.
#=============================================================================

set common_props [list \
    CONFIG.DIFFERENTIAL_IO_STD  {LVDS} \
    CONFIG.SINGLE_IO_STD        {LVCMOS18} \
    CONFIG.APPEND_PIN_NO        {0} \
    CONFIG.ENABLE_PLL_DRP_PORTS {0} \
    CONFIG.RIU_FROM_PLL         {1} \
    CONFIG.ENABLE_PLL0_PLLOUT1  {1} \
    CONFIG.PLL0_CLK_SOURCE      $demo(clk_source) \
    CONFIG.PLL0_INPUT_CLK_FREQ  $demo(ref_freq) \
    CONFIG.PLL0_DATA_SPEED      $demo(data_speed)]

set tx_props [concat $common_props \
    [list CONFIG.BANK "${tx_bank}_(HP)" CONFIG.BUS_DIR {0}] \
    [hsci_bytegroup_props $tx_bank $tx_bytes] \
    [hsci_pin_props [dict get $txcp byte] [dict get $txcp idx] $demo(tx_sig_clk_p) {Clk Fwd}] \
    [hsci_pin_props [dict get $txcn byte] [dict get $txcn idx] $demo(tx_sig_clk_n) {}] \
    [hsci_pin_props [dict get $txdp byte] [dict get $txdp idx] $demo(tx_sig_dat_p) {}] \
    [hsci_pin_props [dict get $txdn byte] [dict get $txdn idx] $demo(tx_sig_dat_n) {}]]

set rx_props [concat $common_props \
    [list CONFIG.BANK "${rx_bank}_(HP)" CONFIG.BUS_DIR {1} \
          CONFIG.ENABLE_N_PINS {0} \
          CONFIG.FIFO_RD_EN_CONTROL {1} \
          CONFIG.PLL0_RX_EXTERNAL_CLK_TO_DATA $demo(rx_clk_to_data)] \
    [hsci_bytegroup_props $rx_bank $rx_bytes] \
    [hsci_pin_props [dict get $rxcp byte] [dict get $rxcp idx] $demo(rx_sig_clk_p) {Strobe}] \
    [hsci_pin_props [dict get $rxcn byte] [dict get $rxcn idx] $demo(rx_sig_clk_n) {}] \
    [hsci_pin_props [dict get $rxdp byte] [dict get $rxdp idx] $demo(rx_sig_dat_p) {Data}] \
    [hsci_pin_props [dict get $rxdn byte] [dict get $rxdn idx] $demo(rx_sig_dat_n) {}]]

# Alle device-queries zijn gedaan. link_design zet DESIGN_MODE op GateLvl en
# close_design zet dat niet terug; create_ip weigert dan.
if {$we_linked} {
    catch {close_design}
    set fs [get_filesets -quiet sources_1]
    if {$fs ne "" && [get_property -quiet DESIGN_MODE $fs] ne "RTL"} {
        set_property DESIGN_MODE RTL $fs
    }
}

#=============================================================================
# 4. IP GENEREREN
#=============================================================================

puts "\n===== HSSIO WIZARDS ============================================="
set tx_keep [list "[dict get $txcp byte],[dict get $txcp idx]" "[dict get $txcn byte],[dict get $txcn idx]" \
                  "[dict get $txdp byte],[dict get $txdp idx]" "[dict get $txdn byte],[dict get $txdn idx]"]
set rx_keep [list "[dict get $rxcp byte],[dict get $rxcp idx]" "[dict get $rxcn byte],[dict get $rxcn idx]" \
                  "[dict get $rxdp byte],[dict get $rxdp idx]" "[dict get $rxdn byte],[dict get $rxdn idx]"]

set ip_tx [hsci_create_ip $demo(ip_tx) $tx_props $tx_keep]
puts "  TX : $demo(ip_tx)  bank $tx_bank"
set ip_rx [hsci_create_ip $demo(ip_rx) $rx_props $rx_keep]
puts "  RX : $demo(ip_rx)  bank $rx_bank"

puts "\n===== KLOK, JTAG-AXI EN CDC ====================================="

# --- MMCM: systeemklok -> XPLL-referentie + een onafhankelijke AXI-klok ------
if {[llength [get_ips -quiet $demo(ip_mmcm)]]} {
    remove_files [get_files -quiet $demo(ip_mmcm).xci]
}
create_ip -name clk_wiz -vendor xilinx.com -library ip -module_name $demo(ip_mmcm)
set ip_mmcm [get_ips $demo(ip_mmcm)]
set mmcm_props [list \
    CONFIG.PRIM_SOURCE                 {Differential_clock_capable_pin} \
    CONFIG.PRIM_IN_FREQ                $demo(sys_clk_mhz) \
    CONFIG.CLKOUT1_USED                {true} \
    CONFIG.CLKOUT1_REQUESTED_OUT_FREQ  $demo(mmcm_out_ref_mhz) \
    CONFIG.CLKOUT2_USED                {true} \
    CONFIG.CLKOUT2_REQUESTED_OUT_FREQ  $demo(mmcm_out_axi_mhz) \
    CONFIG.USE_LOCKED                  {true} \
    CONFIG.USE_RESET                   {false}]
if {[catch {set_property -dict $mmcm_props $ip_mmcm} err]} {
    hsci_fail "clk_wiz weigert deze configuratie:\n            $err"
}
hsci_verify_props $demo(ip_mmcm) $ip_mmcm $mmcm_props
puts "  MMCM     : $demo(ip_mmcm)  $demo(sys_clk_mhz) MHz in ->\
 $demo(mmcm_out_ref_mhz) / $demo(mmcm_out_axi_mhz) MHz uit"

# --- JTAG-AXI master --------------------------------------------------------
# Draait expres op de AXI-klok van de MMCM, niet op hsci_pclk. Zo is de CDC
# hieronder een echte klokdomeinovergang en geen decoratie.
if {[llength [get_ips -quiet $demo(ip_jtag)]]} {
    remove_files [get_files -quiet $demo(ip_jtag).xci]
}
create_ip -name jtag_axi -vendor xilinx.com -library ip -module_name $demo(ip_jtag)
set ip_jtag [get_ips $demo(ip_jtag)]
set jtag_props [list \
    CONFIG.PROTOCOL          {2} \
    CONFIG.M_AXI_DATA_WIDTH  $demo(axi_data_width)]
if {[catch {set_property -dict $jtag_props $ip_jtag} err]} {
    hsci_fail "jtag_axi weigert deze configuratie:\n            $err"
}
hsci_verify_props $demo(ip_jtag) $ip_jtag $jtag_props
puts "  JTAG-AXI : $demo(ip_jtag)  AXI4-Lite master op de $demo(mmcm_out_axi_mhz) MHz klok"

# --- AXI-Lite klokconverter: AXI-klok -> hsci_pclk --------------------------
if {[llength [get_ips -quiet $demo(ip_cdc)]]} {
    remove_files [get_files -quiet $demo(ip_cdc).xci]
}
create_ip -name axi_clock_converter -vendor xilinx.com -library ip -module_name $demo(ip_cdc)
set ip_cdc [get_ips $demo(ip_cdc)]
set cdc_props [list \
    CONFIG.PROTOCOL    {AXI4LITE} \
    CONFIG.DATA_WIDTH  $demo(axi_data_width) \
    CONFIG.ADDR_WIDTH  {32} \
    CONFIG.ID_WIDTH    {0}]
if {[catch {set_property -dict $cdc_props $ip_cdc} err]} {
    hsci_fail "axi_clock_converter weigert deze configuratie:\n            $err"
}
hsci_verify_props $demo(ip_cdc) $ip_cdc $cdc_props
puts "  AXI CDC  : $demo(ip_cdc)  $demo(mmcm_out_axi_mhz) MHz -> hsci_pclk ($pclk_freq MHz)"

foreach ip [list $demo(ip_tx) $demo(ip_rx) $demo(ip_mmcm) $demo(ip_jtag) $demo(ip_cdc)] {
    generate_target {instantiation_template} [get_files ${ip}.xci]
    generate_target all                      [get_files ${ip}.xci]
}

#=============================================================================
# 5. PORT MAP TOETSEN
#=============================================================================

puts "\n===== POORTCHECK ================================================"
set ok 1
if {![hsci_check_ports $demo(ip_tx) $tx_ports]} { set ok 0 }
if {![hsci_check_ports $demo(ip_rx) $rx_ports]} { set ok 0 }

# Voor de andere drie weten we de poortnamen niet uit het hoofd; we halen ze op
# en toetsen alleen of de handvol die de templates gebruiken bestaat.
set mmcm_have [hsci_veo_ports $demo(ip_mmcm)]
set jtag_have [hsci_veo_ports $demo(ip_jtag)]
set cdc_have  [hsci_veo_ports $demo(ip_cdc)]
foreach {naam have willen} [list \
    $demo(ip_mmcm) $mmcm_have {clk_in1_p clk_in1_n clk_out1 clk_out2 locked} \
    $demo(ip_jtag) $jtag_have {aclk aresetn m_axi_awaddr m_axi_wdata m_axi_rdata} \
    $demo(ip_cdc)  $cdc_have  {s_axi_aclk s_axi_aresetn m_axi_aclk m_axi_aresetn}] {
    set miss [list]
    foreach p $willen { if {[lsearch -exact $have $p] < 0} { lappend miss $p } }
    if {[llength $miss]} {
        set ok 0
        puts "  !! $naam : verwachte poort(en) ontbreken: [join $miss {, }]"
        puts "     IP biedt: [join $have {, }]"
    } else {
        puts "  ok $naam : de verwachte poorten bestaan"
    }
}
if {!$ok} {
    hsci_fail "de port map klopt niet met wat de IPs opleveren" \
              "de regels hierboven noemen wat er ontbreekt"
}

#=============================================================================
# 6. FEITEN WEGSCHRIJVEN
#=============================================================================

set tx_bsc_json [list] ; foreach b $tx_bsc_list { lappend tx_bsc_json $b }
set rx_bsc_json [list] ; foreach b $rx_bsc_list { lappend rx_bsc_json $b }

set pins_json [list]
foreach {rol d} [list tx_clk_p $txcp tx_clk_n $txcn tx_dat_p $txdp tx_dat_n $txdn \
                      rx_clk_p $rxcp rx_clk_n $rxcn rx_dat_p $rxdp rx_dat_n $rxdn] {
    lappend pins_json "\"$rol\": [j_obj [list \
        [j_str  pin   [dict get $d pin]] \
        [j_str  func  [dict get $d func]] \
        [j_num  bank  [dict get $d bank]] \
        [j_num  byte  [dict get $d byte]] \
        [j_str  nibl  [dict get $d nibl]] \
        [j_num  idx   [dict get $d idx]] \
        [j_num  bsc   [dict get $d bsc]] \
        [j_num  slice [dict get $d slice]]] "        "]"
}

set out [j_obj [list \
    [j_str  part            $demo(part)] \
    [j_str  speed_grade     [dict get $pi speed]] \
    [j_num  data_speed      $demo(data_speed)] \
    [j_num  pclk_mhz        $pclk_freq] \
    [j_num  fwd_clk_mhz     $fwd_clk_mhz] \
    [j_num  ref_freq        $demo(ref_freq)] \
    [j_num  rx_clk_to_data  $demo(rx_clk_to_data)] \
    [j_num  tx_bank         $tx_bank] \
    [j_num  rx_bank         $rx_bank] \
    [j_ilist tx_bsc         $tx_bsc_json] \
    [j_ilist rx_bsc         $rx_bsc_json] \
    [j_num  rx_slice_strobe $rx_slice_c] \
    [j_num  rx_slice_data   $rx_slice_d] \
    [j_str  ip_tx           $demo(ip_tx)] \
    [j_str  ip_rx           $demo(ip_rx)] \
    [j_str  ip_mmcm         $demo(ip_mmcm)] \
    [j_str  ip_jtag         $demo(ip_jtag)] \
    [j_str  ip_cdc          $demo(ip_cdc)] \
    [j_str  tx_sig_clk_p    $demo(tx_sig_clk_p)] \
    [j_str  tx_sig_clk_n    $demo(tx_sig_clk_n)] \
    [j_str  tx_sig_dat_p    $demo(tx_sig_dat_p)] \
    [j_str  tx_sig_dat_n    $demo(tx_sig_dat_n)] \
    [j_str  rx_sig_clk_p    $demo(rx_sig_clk_p)] \
    [j_str  rx_sig_clk_n    $demo(rx_sig_clk_n)] \
    [j_str  rx_sig_dat_p    $demo(rx_sig_dat_p)] \
    [j_str  rx_sig_dat_n    $demo(rx_sig_dat_n)] \
    [j_str  sys_clk_p       $demo(sys_clk_p)] \
    [j_str  sys_clk_n       $demo(sys_clk_n)] \
    [j_num  sys_clk_mhz     $demo(sys_clk_mhz)] \
    [j_str  sys_clk_iostandard $demo(sys_clk_iostandard)] \
    [j_num  axi_clk_mhz     $demo(mmcm_out_axi_mhz)] \
    [j_num  axi_addr_width  $demo(axi_addr_width)] \
    [j_num  axi_data_width  $demo(axi_data_width)] \
    [j_list tx_ports        $tx_ports] \
    [j_list rx_ports        $rx_ports] \
    "\"pins\": \{\n        [join $pins_json ",\n        "]\n    \}"] "  "]

set fh [open $json_file w]
puts $fh $out
close $fh
puts "\n  geschreven: $json_file"
puts "\n===== KLAAR =====================================================\n"
