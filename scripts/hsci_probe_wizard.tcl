###############################################################################
##  hsci_probe_wizard.tcl
##
##  Answers: is the High Speed SelectIO Wizard in this Vivado newer than
##  ADI's v3.6, and are the CONFIG properties that hsci_hssio_gen.tcl uses
##  still valid?
##
##  Runs nothing destructive -- creates a throwaway IP in an in-memory
##  project, reads out the properties and prints a verdict.
##
##      vivado -mode batch -source hsci_probe_wizard.tcl
###############################################################################

set part_name "xczu17eg-ffvd1760-1-e"    ;# <-- your part

# Properties that hsci_hssio_gen.tcl sets, with the value it would set.
# (BYTE properties are tested separately on a representative pin.)
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

# Per-pin properties, tested on BYTE0_PIN4.
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

puts "\n===== AVAILABLE VERSIONS ========================================"
set defs [get_ipdefs -quiet -filter {NAME == high_speed_selectio_wiz}]
if {[llength $defs] == 0} {
    error "high_speed_selectio_wiz does not exist in this Vivado / for this part"
}
foreach d $defs {
    puts [format "  %-60s  %s" $d [get_property -quiet VERSION $d]]
}

catch {remove_files [get_files -quiet hsci_probe_tmp.xci]}
create_ip -name high_speed_selectio_wiz -vendor xilinx.com -library ip \
          -module_name hsci_probe_tmp
set ip [get_ips hsci_probe_tmp]
# IP objects have no VERSION property; the version lives in IPDEF
puts "\n  created with version : [lindex [split [get_property IPDEF $ip] :] 3]"
puts "  ADI's vcu118 uses    : 3.6"

set have [list]
foreach p [list_property $ip] {
    if {[string match "CONFIG.*" $p]} {
        lappend have [string range $p 7 end]
    }
}
puts "  number of CONFIG properties: [llength $have]"

#-----------------------------------------------------------------------------
puts "\n===== PROPERTIES hsci_hssio_gen.tcl SETS ========================"
puts [format "  %-30s %-8s %-14s %s" "property" "exists" "current" "legal values"]
puts "  [string repeat - 88]"

set missing [list]
set badval  [list]

foreach {p v} $want {
    if {[lsearch -exact $have $p] < 0} {
        lappend missing $p
        puts [format "  %-30s %-8s" $p "NO"]
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
    if {$shown eq ""} { set shown "<free value>" }
    puts [format "  %-30s %-8s %-14s %s" $p "yes" $cur $shown]

    # if it's an enum, check that our value is in it
    if {$v ne "" && [llength $legal] > 0 && [lsearch -exact $legal $v] < 0} {
        lappend badval "$p: we set '$v', legal is \{$legal\}"
    }
}

puts "\n===== PER-PIN PROPERTIES (BYTE0_PIN4) =========================="
foreach p $want_pin {
    if {[lsearch -exact $have $p] < 0} {
        lappend missing $p
        puts [format "  %-30s %s" $p "NO"]
    } else {
        set legal [list_property_value -quiet CONFIG.$p $ip]
        if {$legal eq ""} { set legal "<free value>" } else { set legal [join $legal ", "] }
        puts [format "  %-30s yes     %s" $p $legal]
    }
}

#-----------------------------------------------------------------------------
puts "\n===== NEW COMPARED TO ADI's 3.6 ================================="
# ADI's 3.6 set, without the per-pin properties (there are hundreds of those)
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
    puts "  no new non-pin properties"
} else {
    puts "  [llength $news] property(s) ADI's 3.6 config doesn't set:"
    foreach p [lsort $news] {
        puts [format "    %-32s = %s" $p [get_property -quiet CONFIG.$p $ip]]
    }
}

#-----------------------------------------------------------------------------
puts "\n===== VERDICT ==================================================="
if {[llength $missing] == 0 && [llength $badval] == 0} {
    puts "  OK -- all properties hsci_hssio_gen.tcl uses exist"
    puts "        and accept the values the script sets."
} else {
    foreach p $missing { puts "  MISSING   : $p" }
    foreach b $badval  { puts "  VALUE     : $b" }
    puts "\n  Adjust hsci_hssio_gen.tcl before running it."
}

puts "\n  Note: this says nothing about the PORT NAMES of the generated module."
puts "  hsci_hssio_gen.tcl checks those itself against the .veo template.\n"