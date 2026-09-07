###############################################################################
##  hsci_hssio_min.tcl
##
##  The shortest path from eight package pins to two High Speed SelectIO
##  Wizard instances. One file, no dependencies, no rule checks: this assumes
##  your pinout is correct. If it isn't, the wizard itself will say what's
##  wrong -- if you want that explained up front, use hsci_hssio_gen.tcl.
##
##      vivado -mode batch -source scripts/hsci_hssio_min.tcl
##
##  What's not in here but needs to be, and why it looks the way it does:
##
##    - BUS_DIR 0 is TX_ONLY, 1 is RX_ONLY. Put the TX on 3 (TX+RX) and the
##      wizard silently clamps the clock source to a bank pin at datarate/2.
##    - ENABLE_BYTE2_PIN0 and ENABLE_BYTE3_PIN12 default ON and clash with
##      everything. Disable them explicitly.
##    - Everything in one set_property -dict; setting them one by one fails
##      on intermediate states.
##    - link_design sets DESIGN_MODE to GateLvl and close_design doesn't set
##      it back, after which create_ip refuses.
##
##  Deliberately left out, compared with the full generator (all 990 CONFIG
##  properties are otherwise identical):
##
##    - the BYTE?_PIN?_LOC/NAME block for all 13 pins of every byte group.
##      The wizard derives those itself from CONFIG.BANK and lands on exactly
##      the same pins.
##    - SINGLE_IO_STD. Stays at NONE, which is fine as long as there are no
##      single-ended pins in the same byte group. If there are, set it to
##      your bank voltage, e.g. LVCMOS18.
###############################################################################

#--- configuration ------------------------------------------------------------
set part "xczu17eg-ffvd1760-1-e"
set rate 1600                     ;# Mb/s on the wire
set ref  200.000                  ;# MHz reference; must be rate/N
set rx_clk_to_data 4              ;# a property of the slave, not of the FPGA

#            pin P  pin N   signal name P      signal name N
set tx_clk { R26    P26     hsci_mosi_clk_p    hsci_mosi_clk_n }
set tx_dat { M27    M28     hsci_mosi_d_p      hsci_mosi_d_n   }
set rx_clk { C20    B21     hsci_miso_clk_p    hsci_miso_clk_n }
set rx_dat { D20    C21     hsci_miso_d_p      hsci_miso_d_n   }

set ip_tx "hssio_wiz_hsci_tx"
set ip_rx "hssio_wiz_hsci_rx"

#--- pin -> bank, byte group, bitslice ----------------------------------------
proc pinfo {p} {
    set pp [get_package_pins -quiet $p]
    if {$pp eq ""} { error "pin $p does not exist on this part" }
    set f [get_property PIN_FUNC $pp]
    if {![regexp {_T(\d)([LU])_N(\d+)} $f -> b n i]} {
        error "pin $p ($f) is not in a byte group"
    }
    return [dict create bank [get_property BANK $pp] byte $b idx $i func $f \
                        bsc [expr {$b * 2 + ($n eq "U")}] slice [expr {$b * 13 + $i}]]
}

proc pinprops {d name {strobe ""}} {
    set b [dict get $d byte] ; set i [dict get $d idx]
    set l [list CONFIG.ENABLE_BYTE${b}_PIN${i}      {true} \
                CONFIG.BYTE${b}_PIN${i}_SIGNAL_NAME $name \
                CONFIG.BYTE${b}_PIN${i}_SIG_TYPE    {DIFF}]
    if {$strobe ne ""} { lappend l CONFIG.BYTE${b}_PIN${i}_DATA_STROBE $strobe }
    return $l
}

#--- analysis -----------------------------------------------------------------
create_project -in_memory -part $part
link_design -part $part -name hsci_pins        ;# only after this do the pins exist

foreach v {tx_clk tx_dat rx_clk rx_dat} {
    set s [set $v]
    set ${v}_p [pinfo [lindex $s 0]]
    set ${v}_n [pinfo [lindex $s 1]]
}

set tx_bsc [lsort -unique -integer [list [dict get $tx_clk_p bsc] [dict get $tx_dat_p bsc]]]
set rx_bsc [lsort -unique -integer [list [dict get $rx_clk_p bsc] [dict get $rx_dat_p bsc]]]

close_design
set_property DESIGN_MODE RTL [get_filesets sources_1]

#--- IP -----------------------------------------------------------------------
set common [list \
    CONFIG.DIFFERENTIAL_IO_STD {LVDS}  CONFIG.APPEND_PIN_NO {0} \
    CONFIG.RIU_FROM_PLL        {1}     CONFIG.ENABLE_PLL0_PLLOUT1 {1} \
    CONFIG.PLL0_CLK_SOURCE     {BUFG_TO_PLL} \
    CONFIG.PLL0_INPUT_CLK_FREQ $ref    CONFIG.PLL0_DATA_SPEED $rate \
    CONFIG.ENABLE_BYTE2_PIN0   {false} CONFIG.ENABLE_BYTE3_PIN12 {false}]

set props(tx) [concat $common \
    [list CONFIG.BANK "[dict get $tx_clk_p bank]_(HP)" CONFIG.BUS_DIR {0}] \
    [pinprops $tx_clk_p [lindex $tx_clk 2] {Clk Fwd}] \
    [pinprops $tx_clk_n [lindex $tx_clk 3]] \
    [pinprops $tx_dat_p [lindex $tx_dat 2]] \
    [pinprops $tx_dat_n [lindex $tx_dat 3]]]

set props(rx) [concat $common \
    [list CONFIG.BANK "[dict get $rx_clk_p bank]_(HP)" CONFIG.BUS_DIR {1} \
          CONFIG.ENABLE_N_PINS {0} CONFIG.FIFO_RD_EN_CONTROL {1} \
          CONFIG.PLL0_RX_EXTERNAL_CLK_TO_DATA $rx_clk_to_data] \
    [pinprops $rx_clk_p [lindex $rx_clk 2] {Strobe}] \
    [pinprops $rx_clk_n [lindex $rx_clk 3]] \
    [pinprops $rx_dat_p [lindex $rx_dat 2] {Data}] \
    [pinprops $rx_dat_n [lindex $rx_dat 3]]]

foreach {k name} [list tx $ip_tx rx $ip_rx] {
    if {[llength [get_ips -quiet $name]]} { remove_files [get_files ${name}.xci] }
    create_ip -name high_speed_selectio_wiz -vendor xilinx.com -library ip -module_name $name
    set_property -dict $props($k) [get_ips $name]
    generate_target {instantiation_template} [get_files ${name}.xci]
}

#--- the port names that come out here ----------------------------------------
puts "\n$ip_tx  (bank [dict get $tx_clk_p bank])"
foreach b $tx_bsc { puts "  dly_rdy_bsc$b vtc_rdy_bsc$b en_vtc_bsc$b" }
foreach {d spec} [list $tx_clk_p $tx_clk $tx_dat_p $tx_dat] {
    puts "  [lindex $spec 2] [lindex $spec 3] data_from_fabric_[lindex $spec 2]"
}
puts "  clk rst pll0_locked pll0_clkout0 rst_seq_done"

puts "\n$ip_rx  (bank [dict get $rx_clk_p bank])"
foreach b $rx_bsc { puts "  dly_rdy_bsc$b vtc_rdy_bsc$b en_vtc_bsc$b" }
foreach {d spec} [list $rx_clk_p $rx_clk $rx_dat_p $rx_dat] {
    puts "  [lindex $spec 2] [lindex $spec 3] data_to_fabric_[lindex $spec 2]"
}
foreach s [list [dict get $rx_clk_p slice] [dict get $rx_dat_p slice]] {
    puts "  fifo_rd_clk_$s fifo_rd_en_$s fifo_empty_$s"
}
puts "  clk rst pll0_locked pll0_clkout0 rst_seq_done"
puts "\nhsci_pclk = [expr {$rate / 8.0}] MHz, forwarded clock [expr {$rate / 2.0}] MHz\n"