###############################################################################
##  hsci_probe_wizard.tcl
##
##  Beantwoordt: is de High Speed SelectIO Wizard in deze Vivado nieuwer dan
##  ADI's v3.6, en zijn de CONFIG-properties die hsci_hssio_gen.tcl gebruikt
##  nog steeds geldig?
##
##  Draait niets destructiefs -- maakt een throwaway IP in een in-memory
##  project, leest de properties uit en print een verdict.
##
##      vivado -mode batch -source hsci_probe_wizard.tcl
###############################################################################

set part_name "xczu17eg-ffvd1760-1-e"    ;# <-- jouw part

# Properties die hsci_hssio_gen.tcl zet, met de waarde die het zou zetten.
# (BYTE-properties worden apart getest op een representatieve pin.)
set want {
    DIFFERENTIAL_IO_STD          LVDS
    ENABLE_N_PINS                0
    APPEND_PIN_NO                0
    ENABLE_PLL_DRP_PORTS         0
    RIU_FROM_PLL                 1
    PLL0_CLK_SOURCE              BUFG_TO_PLL
    PLL0_INPUT_CLK_FREQ          200.000
    PLL0_DATA_SPEED              1600
    PLL0_PLLOUT0                 200.000
    PLL0_RX_EXTERNAL_CLK_TO_DATA 3
    FIFO_RD_EN_CONTROL           1
    TX_PRE_EMPHASIS_D            FALSE
    BUS_DIR                      3
    BANK                         {}
    PLL_LOCS                     {}
}

# Per-pin properties, getest op BYTE0_PIN4.
set want_pin {
    ENABLE_BYTE0_PIN4
    BYTE0_PIN4_SIGNAL_NAME
    BYTE0_PIN4_SIG_TYPE
    BYTE0_PIN4_DATA_STROBE
    BYTE0_PIN4_BUS_DIR
    BYTE0_PIN4_INIT
    BYTE0_PIN4_LOC
}

#=============================================================================

if {[llength [current_project -quiet]] == 0} {
    create_project -in_memory -part $part_name
}

puts "\n===== BESCHIKBARE VERSIES ======================================="
set defs [get_ipdefs -quiet -filter {NAME == high_speed_selectio_wiz}]
if {[llength $defs] == 0} {
    error "high_speed_selectio_wiz bestaat niet in deze Vivado / voor dit part"
}
foreach d $defs {
    puts [format "  %-60s  %s" $d [get_property -quiet VERSION $d]]
}

catch {remove_files [get_files -quiet hsci_probe_tmp.xci]}
create_ip -name high_speed_selectio_wiz -vendor xilinx.com -library ip \
          -module_name hsci_probe_tmp
set ip [get_ips hsci_probe_tmp]
# IP-objecten hebben geen VERSION property; de versie zit in IPDEF
puts "\n  aangemaakt met versie : [lindex [split [get_property IPDEF $ip] :] 3]"
puts "  ADI's vcu118 gebruikt : 3.6"

set have [list]
foreach p [list_property $ip] {
    if {[string match "CONFIG.*" $p]} {
        lappend have [string range $p 7 end]
    }
}
puts "  aantal CONFIG properties: [llength $have]"

#-----------------------------------------------------------------------------
puts "\n===== PROPERTIES DIE hsci_hssio_gen.tcl ZET ====================="
puts [format "  %-30s %-8s %-14s %s" "property" "bestaat" "huidig" "legale waarden"]
puts "  [string repeat - 88]"

set missing [list]
set badval  [list]

foreach {p v} $want {
    if {[lsearch -exact $have $p] < 0} {
        lappend missing $p
        puts [format "  %-30s %-8s" $p "NEE"]
        continue
    }
    set cur  [get_property -quiet CONFIG.$p $ip]
    set legal [list_property_value -quiet CONFIG.$p $ip]
    set shown $legal
    if {[llength $legal] > 6} {
        set shown "[join [lrange $legal 0 5] {, }] ... ([llength $legal])"
    } else {
        set shown [join $legal ", "]
    }
    if {$shown eq ""} { set shown "<vrije waarde>" }
    puts [format "  %-30s %-8s %-14s %s" $p "ja" $cur $shown]

    # als het een enum is, controleer of onze waarde erin zit
    if {$v ne "" && [llength $legal] > 0 && [lsearch -exact $legal $v] < 0} {
        lappend badval "$p: wij zetten '$v', legaal is \{$legal\}"
    }
}

puts "\n===== PER-PIN PROPERTIES (BYTE0_PIN4) =========================="
foreach p $want_pin {
    if {[lsearch -exact $have $p] < 0} {
        lappend missing $p
        puts [format "  %-30s %s" $p "NEE"]
    } else {
        set legal [list_property_value -quiet CONFIG.$p $ip]
        if {$legal eq ""} { set legal "<vrije waarde>" } else { set legal [join $legal ", "] }
        puts [format "  %-30s ja      %s" $p $legal]
    }
}

#-----------------------------------------------------------------------------
puts "\n===== NIEUW T.O.V. ADI's 3.6 ===================================="
# ADI's 3.6 set, zonder de per-pin properties (die zijn er honderden)
set adi36 {
    APPEND_PIN_NO BANK BUS_DIR DIFFERENTIAL_IO_STD ENABLE_N_PINS
    ENABLE_PLL_DRP_PORTS FIFO_RD_EN_CONTROL PLL0_CLK_SOURCE PLL0_DATA_SPEED
    PLL0_INPUT_CLK_FREQ PLL0_PLLOUT0 PLL0_RX_EXTERNAL_CLK_TO_DATA PLL_LOCS
    RIU_FROM_PLL TX_PRE_EMPHASIS_D
}
set news [list]
foreach p $have {
    if {[regexp {^(ENABLE_)?BYTE\d} $p]} { continue }
    if {[lsearch -exact $adi36 $p] < 0} { lappend news $p }
}
if {[llength $news] == 0} {
    puts "  geen nieuwe niet-pin properties"
} else {
    puts "  [llength $news] property(s) die ADI's 3.6 config niet zet:"
    foreach p [lsort $news] {
        puts [format "    %-32s = %s" $p [get_property -quiet CONFIG.$p $ip]]
    }
}

#-----------------------------------------------------------------------------
puts "\n===== VERDICT ==================================================="
if {[llength $missing] == 0 && [llength $badval] == 0} {
    puts "  OK -- alle properties die hsci_hssio_gen.tcl gebruikt bestaan"
    puts "        en accepteren de waarden die het script zet."
} else {
    foreach p $missing { puts "  ONTBREEKT : $p" }
    foreach b $badval  { puts "  WAARDE    : $b" }
    puts "\n  Pas hsci_hssio_gen.tcl aan voordat je hem draait."
}

puts "\n  Let op: dit zegt niets over de POORTNAMEN van de gegenereerde module."
puts "  hsci_hssio_gen.tcl controleert die zelf tegen de .veo template.\n"
