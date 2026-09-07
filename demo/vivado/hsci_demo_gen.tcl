###############################################################################
##  hsci_demo_gen.tcl
##
##  The Vivado half of the demo. Called by demo/build_demo.py, it does
##  everything you need the device database for:
##
##    1. analyse the eight HSCI pins and check the rules
##    2. create the two High Speed SelectIO Wizard instances
##       (derived from the pins, not retyped from docs/hssio_for_demo.txt)
##    3. create the MMCM, the JTAG-AXI master and the AXI-Lite clock converter
##    4. check the predicted port map against the real .veo
##    5. write out everything the templates need as JSON
##
##  The analysis and the wizard helpers come from scripts/hsci_hssio_lib.tcl, so
##  the demo and the generator use the same engine.
##
##      vivado -mode batch -source hsci_demo_gen.tcl -tclargs <cfg.tcl> <out.json>
###############################################################################

set cfg_file  [lindex $argv 0]
set json_file [lindex $argv 1]
set here      [file normalize [file dirname [info script]]]

source [file join $here .. .. scripts hsci_hssio_lib.tcl]
source $cfg_file      ;# fills the demo(...) array

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
# 1. DEVICE AND PINS
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

puts "\n===== PIN ANALYSIS ==============================================="
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

puts "\n===== RULE CHECK ================================================="
hsci_check_pair "TX clkfwd" $txcp $txcn
hsci_check_pair "TX data"   $txdp $txdn
hsci_check_pair "RX strobe" $rxcp $rxcn
hsci_check_pair "RX data"   $rxdp $rxdn
puts "ok  four real differential pairs"

set tx_bank [dict get $txcp bank]
set rx_bank [dict get $rxcp bank]
hsci_check_bank_hp $tx_bank "TX"
hsci_check_bank_hp $rx_bank "RX"
puts "ok  bank $tx_bank (TX) and bank $rx_bank (RX) are HP banks"

if {[dict get $txdp bank] != $tx_bank || [dict get $txcp byte] != [dict get $txdp byte]} {
    hsci_fail "TX clkfwd and data are not in the same byte group" \
              "both TX signals share the PLL clock of their byte group"
}
set tx_bsc_list [lsort -unique -integer [list [dict get $txcp bsc] [dict get $txdp bsc]]]
puts "ok  TX clkfwd + data in byte group [dict get $txcp byte] (bsc [join $tx_bsc_list {, }])"

set rx_bsc_list [hsci_check_rx_group $rxcp $rxdp]
puts "ok  RX strobe on [dict get $rxcp clkcap] pin, byte group [dict get $rxcp byte]\
 (bsc [join $rx_bsc_list {, }])"

#=============================================================================
# 2. DERIVED NUMBERS
#=============================================================================

set pclk_freq   [expr {double($demo(data_speed)) / 8.0}]
set fwd_clk_mhz [expr {double($demo(data_speed)) / 2.0}]
set tx_bytes    [lsort -unique -integer [list [dict get $txcp byte] [dict get $txdp byte]]]
set rx_bytes    [lsort -unique -integer [list [dict get $rxcp byte] [dict get $rxdp byte]]]
set rx_slice_c  [dict get $rxcp slice]
set rx_slice_d  [dict get $rxdp slice]

puts "\n===== DERIVED ==================================================="
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
#  Same shape as docs/hssio_for_demo.txt, but derived from the pins:
#  BANK, BYTE?_PIN? and the bsc indices all come from the device database.
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

# All device queries are done. link_design sets DESIGN_MODE to GateLvl and
# close_design doesn't set it back; create_ip then refuses.
if {$we_linked} {
    catch {close_design}
    set fs [get_filesets -quiet sources_1]
    if {$fs ne "" && [get_property -quiet DESIGN_MODE $fs] ne "RTL"} {
        set_property DESIGN_MODE RTL $fs
    }
}

#=============================================================================
# 4. IP GENERATION
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

puts "\n===== CLOCK, JTAG-AXI AND CDC ==================================="

# --- MMCM: system clock -> XPLL reference + an independent AXI clock --------
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
    hsci_fail "clk_wiz refuses this configuration:\n            $err"
}
hsci_verify_props $demo(ip_mmcm) $ip_mmcm $mmcm_props
puts "  MMCM     : $demo(ip_mmcm)  $demo(sys_clk_mhz) MHz in ->\
 $demo(mmcm_out_ref_mhz) / $demo(mmcm_out_axi_mhz) MHz out"

# --- JTAG-AXI master --------------------------------------------------------
# Deliberately runs on the MMCM's AXI clock, not on hsci_pclk. That way the
# CDC below is a real clock domain crossing, not decoration.
if {[llength [get_ips -quiet $demo(ip_jtag)]]} {
    remove_files [get_files -quiet $demo(ip_jtag).xci]
}
create_ip -name jtag_axi -vendor xilinx.com -library ip -module_name $demo(ip_jtag)
set ip_jtag [get_ips $demo(ip_jtag)]
set jtag_props [list \
    CONFIG.PROTOCOL          {2} \
    CONFIG.M_AXI_DATA_WIDTH  $demo(axi_data_width)]
if {[catch {set_property -dict $jtag_props $ip_jtag} err]} {
    hsci_fail "jtag_axi refuses this configuration:\n            $err"
}
hsci_verify_props $demo(ip_jtag) $ip_jtag $jtag_props
puts "  JTAG-AXI : $demo(ip_jtag)  AXI4-Lite master on the $demo(mmcm_out_axi_mhz) MHz clock"

# --- AXI-Lite clock converter: AXI clock -> hsci_pclk -----------------------
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
    hsci_fail "axi_clock_converter refuses this configuration:\n            $err"
}
hsci_verify_props $demo(ip_cdc) $ip_cdc $cdc_props
puts "  AXI CDC  : $demo(ip_cdc)  $demo(mmcm_out_axi_mhz) MHz -> hsci_pclk ($pclk_freq MHz)"

foreach ip [list $demo(ip_tx) $demo(ip_rx) $demo(ip_mmcm) $demo(ip_jtag) $demo(ip_cdc)] {
    generate_target {instantiation_template} [get_files ${ip}.xci]
    generate_target all                      [get_files ${ip}.xci]
}

#=============================================================================
# 5. PORT MAP CHECK
#=============================================================================

puts "\n===== PORT CHECK ================================================"
set ok 1
if {![hsci_check_ports $demo(ip_tx) $tx_ports]} { set ok 0 }
if {![hsci_check_ports $demo(ip_rx) $rx_ports]} { set ok 0 }

# For the other three we don't know the port names by heart; we fetch them and
# only check that the handful the templates use exists.
set mmcm_have [hsci_veo_ports $demo(ip_mmcm)]
set jtag_have [hsci_veo_ports $demo(ip_jtag)]
set cdc_have  [hsci_veo_ports $demo(ip_cdc)]
foreach {name have want} [list \
    $demo(ip_mmcm) $mmcm_have {clk_in1_p clk_in1_n clk_out1 clk_out2 locked} \
    $demo(ip_jtag) $jtag_have {aclk aresetn m_axi_awaddr m_axi_wdata m_axi_rdata} \
    $demo(ip_cdc)  $cdc_have  {s_axi_aclk s_axi_aresetn m_axi_aclk m_axi_aresetn}] {
    set miss [list]
    foreach p $want { if {[lsearch -exact $have $p] < 0} { lappend miss $p } }
    if {[llength $miss]} {
        set ok 0
        puts "  !! $name : expected port(s) missing: [join $miss {, }]"
        puts "     IP offers: [join $have {, }]"
    } else {
        puts "  ok $name : the expected ports exist"
    }
}
if {!$ok} {
    hsci_fail "the port map doesn't match what the IPs produce" \
              "the rules above name what is missing"
}

#=============================================================================
# 6. WRITE OUT THE FACTS
#=============================================================================

set tx_bsc_json [list] ; foreach b $tx_bsc_list { lappend tx_bsc_json $b }
set rx_bsc_json [list] ; foreach b $rx_bsc_list { lappend rx_bsc_json $b }

set pins_json [list]
foreach {role d} [list tx_clk_p $txcp tx_clk_n $txcn tx_dat_p $txdp tx_dat_n $txdn \
                      rx_clk_p $rxcp rx_clk_n $rxcn rx_dat_p $rxdp rx_dat_n $rxdn] {
    lappend pins_json "\"$role\": [j_obj [list \
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
puts "\n  written: $json_file"
puts "\n===== DONE ======================================================\n"
