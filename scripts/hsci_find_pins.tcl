###############################################################################
##  hsci_find_pins.tcl
##
##  Zoekt op een gegeven part alle pin-combinaties die aan de HSCI/HSSIO regels
##  voldoen, en print ze in cfg()-vorm klaar om te plakken in hsci_hssio_gen.tcl.
##
##  RX vereist: strobe op de QBC/DBC pin (N0/N1 of N6/N7) van een nibble, met
##              de data op een ander diff-paar in DEZELFDE nibble.
##  TX vereist: twee diff-paren in dezelfde byte group.
##
##      vivado -mode batch -source hsci_find_pins.tcl -tclargs <part> [max]
###############################################################################

set part_name [expr {[llength $argv] > 0 ? [lindex $argv 0] : "xczu7ev-ffvf1517-2-e"}]
set max_show  [expr {[llength $argv] > 1 ? [lindex $argv 1] : 4}]

if {[llength [current_project -quiet]] == 0} {
    create_project -in_memory -part $part_name
}
if {[llength [get_parts -quiet $part_name]] != 1} {
    puts "part '$part_name' niet bekend in deze installatie"
    return
}

puts "\n===== $part_name ================================================"

# Package pins en IO banks bestaan pas na link_design.
if {[llength [get_package_pins -quiet]] == 0} {
    puts "  device database laden (link_design)..."
    if {[catch {link_design -part $part_name -name hsci_pinquery} e]} {
        puts "  link_design faalde: $e"
        return
    }
}

# bank -> byte -> idx -> {pinnaam func nibble}
set tbl [dict create]
foreach bank [get_iobanks -quiet] {
    if {[get_property -quiet BANK_TYPE $bank] ne "BT_HIGH_PERFORMANCE"} { continue }
    foreach pp [get_package_pins -quiet -filter "BANK == $bank"] {
        set func [get_property PIN_FUNC $pp]
        if {![regexp {_T(\d)([LU])_N(\d+)} $func -> byte nib idx]} { continue }
        dict set tbl $bank $byte $idx [list [get_property NAME $pp] $func $nib]
    }
}

set banks [lsort -integer [dict keys $tbl]]
if {[llength $banks] == 0} {
    puts "  geen HP banks gevonden op dit part"
    return
}
puts "  HP banks: [join $banks {, }]"

# Is er een echt diff-paar op N<i>/N<i+1>?
proc pair_ok {tbl bank byte i} {
    if {![dict exists $tbl $bank $byte $i] || ![dict exists $tbl $bank $byte [expr {$i+1}]]} { return 0 }
    set fp [lindex [dict get $tbl $bank $byte $i] 1]
    set fn [lindex [dict get $tbl $bank $byte [expr {$i+1}]] 1]
    if {![regexp {^IO_L(\d+)P_} $fp -> a]} { return 0 }
    if {![regexp {^IO_L(\d+)N_} $fn -> b]} { return 0 }
    return [expr {$a == $b}]
}
proc pin_of {tbl bank byte i} { return [lindex [dict get $tbl $bank $byte $i] 0] }
proc fun_of {tbl bank byte i} { return [lindex [dict get $tbl $bank $byte $i] 1] }

# --- RX kandidaten: strobe op N0 of N6 (moet QBC/DBC zijn), data elders in
#     dezelfde nibble ---------------------------------------------------------
set rx_cand [list]
foreach bank $banks {
    foreach byte [lsort -integer [dict keys [dict get $tbl $bank]]] {
        foreach {sidx nib dpins} {0 L {2 4} 6 U {8 10}} {
            if {![pair_ok $tbl $bank $byte $sidx]} { continue }
            if {![regexp {_(QBC|DBC)_} [fun_of $tbl $bank $byte $sidx]]} { continue }
            foreach d $dpins {
                if {![pair_ok $tbl $bank $byte $d]} { continue }
                lappend rx_cand [list $bank $byte $nib $sidx $d]
            }
        }
    }
}

# --- TX kandidaten: twee diff-paren in dezelfde byte group -------------------
set tx_cand [list]
foreach bank $banks {
    foreach byte [lsort -integer [dict keys [dict get $tbl $bank]]] {
        set pairs [list]
        foreach i {0 2 4 6 8 10} { if {[pair_ok $tbl $bank $byte $i]} { lappend pairs $i } }
        if {[llength $pairs] < 2} { continue }
        # klokpaar bij voorkeur in de andere nibble dan het datapaar (zoals ADI)
        foreach c $pairs {
            foreach d $pairs {
                if {$c == $d} { continue }
                lappend tx_cand [list $bank $byte $c $d]
            }
        }
    }
}

puts "  RX kandidaten: [llength $rx_cand]    TX kandidaten: [llength $tx_cand]"

# --- combineren, TX en RX bij voorkeur in verschillende banks ----------------
set combos [list]
foreach rx $rx_cand {
    lassign $rx rb rbyte rnib rs rd
    foreach tx $tx_cand {
        lassign $tx tb tbyte tc td
        if {$tb == $rb && $tbyte == $rbyte} { continue }   ;# niet dezelfde byte group
        set score [expr {($tb != $rb) ? 0 : 1}]            ;# andere bank = beter
        lappend combos [list $score $rx $tx]
    }
}
set combos [lsort -integer -index 0 $combos]

if {[llength $combos] == 0} {
    puts "\n  geen geldige combinatie gevonden op dit part"
    return
}

puts "\n===== TOP $max_show COMBINATIES ================================="
set n 0
foreach c $combos {
    if {$n >= $max_show} break
    lassign $c score rx tx
    lassign $rx rb rbyte rnib rs rd
    lassign $tx tb tbyte tc td
    incr n
    set rbsc [expr {$rbyte*2 + ($rnib eq "U" ? 1 : 0)}]
    puts "\n--- optie $n : RX bank $rb byte${rbyte}${rnib} (bsc $rbsc), TX bank $tb byte$tbyte\
[expr {$score==0 ? {} : {   (zelfde bank!)}}]"
    puts "set cfg(part)       \"$part_name\""
    puts "set cfg(rx_clk_p)   \"[pin_of $tbl $rb $rbyte $rs]\"   ;# [fun_of $tbl $rb $rbyte $rs]"
    puts "set cfg(rx_clk_n)   \"[pin_of $tbl $rb $rbyte [expr {$rs+1}]]\"   ;# [fun_of $tbl $rb $rbyte [expr {$rs+1}]]"
    puts "set cfg(rx_dat_p)   \"[pin_of $tbl $rb $rbyte $rd]\"   ;# [fun_of $tbl $rb $rbyte $rd]"
    puts "set cfg(rx_dat_n)   \"[pin_of $tbl $rb $rbyte [expr {$rd+1}]]\"   ;# [fun_of $tbl $rb $rbyte [expr {$rd+1}]]"
    puts "set cfg(tx_clk_p)   \"[pin_of $tbl $tb $tbyte $tc]\"   ;# [fun_of $tbl $tb $tbyte $tc]"
    puts "set cfg(tx_clk_n)   \"[pin_of $tbl $tb $tbyte [expr {$tc+1}]]\"   ;# [fun_of $tbl $tb $tbyte [expr {$tc+1}]]"
    puts "set cfg(tx_dat_p)   \"[pin_of $tbl $tb $tbyte $td]\"   ;# [fun_of $tbl $tb $tbyte $td]"
    puts "set cfg(tx_dat_n)   \"[pin_of $tbl $tb $tbyte [expr {$td+1}]]\"   ;# [fun_of $tbl $tb $tbyte [expr {$td+1}]]"
}
puts ""
