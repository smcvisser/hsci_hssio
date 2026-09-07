###############################################################################
##  hsci_find_pins.tcl
##
##  On a given part, finds every pin combination that satisfies the HSCI/HSSIO
##  rules, and prints them as cfg() lines ready to paste into
##  hsci_hssio_gen.tcl.
##
##  RX needs: strobe on the QBC/DBC pin (N0/N1 or N6/N7) of a nibble, with
##            the data on another diff pair in the SAME nibble.
##  TX needs: two diff pairs in the same byte group.
##
##      vivado -mode batch -source hsci_find_pins.tcl -tclargs <part> [max]
###############################################################################

set part_name [expr {[llength $argv] > 0 ? [lindex $argv 0] : "xczu7ev-ffvf1517-2-e"}]
set max_show  [expr {[llength $argv] > 1 ? [lindex $argv 1] : 4}]

if {[llength [current_project -quiet]] == 0} {
    create_project -in_memory -part $part_name
}
if {[llength [get_parts -quiet $part_name]] != 1} {
    puts "part '$part_name' not known in this installation"
    return
}

puts "\n===== $part_name ================================================"

# Package pins and IO banks only exist after link_design.
if {[llength [get_package_pins -quiet]] == 0} {
    puts "  loading device database (link_design)..."
    if {[catch {link_design -part $part_name -name hsci_pinquery} e]} {
        puts "  link_design failed: $e"
        return
    }
}

# bank -> byte -> idx -> {pin name func nibble}
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
    puts "  no HP banks found on this part"
    return
}
puts "  HP banks: [join $banks {, }]"

# Is there a real diff pair on N<i>/N<i+1>?
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

# --- RX candidates: strobe on N0 or N6 (must be QBC/DBC), data elsewhere in
#     the same nibble ---------------------------------------------------------
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

# --- TX candidates: two diff pairs in the same byte group --------------------
set tx_cand [list]
foreach bank $banks {
    foreach byte [lsort -integer [dict keys [dict get $tbl $bank]]] {
        set pairs [list]
        foreach i {0 2 4 6 8 10} { if {[pair_ok $tbl $bank $byte $i]} { lappend pairs $i } }
        if {[llength $pairs] < 2} { continue }
        # clock pair preferably in the other nibble than the data pair (like ADI)
        foreach c $pairs {
            foreach d $pairs {
                if {$c == $d} { continue }
                lappend tx_cand [list $bank $byte $c $d]
            }
        }
    }
}

puts "  RX candidates: [llength $rx_cand]    TX candidates: [llength $tx_cand]"

# --- combine; TX and RX preferably in different banks ------------------------
set combos [list]
foreach rx $rx_cand {
    lassign $rx rb rbyte rnib rs rd
    foreach tx $tx_cand {
        lassign $tx tb tbyte tc td
        if {$tb == $rb && $tbyte == $rbyte} { continue }   ;# not the same byte group
        set score [expr {($tb != $rb) ? 0 : 1}]            ;# different bank = better
        lappend combos [list $score $rx $tx]
    }
}
set combos [lsort -integer -index 0 $combos]

if {[llength $combos] == 0} {
    puts "\n  no valid combination found on this part"
    return
}

puts "\n===== TOP $max_show COMBINATIONS ================================"
set n 0
foreach c $combos {
    if {$n >= $max_show} break
    lassign $c score rx tx
    lassign $rx rb rbyte rnib rs rd
    lassign $tx tb tbyte tc td
    incr n
    set rbsc [expr {$rbyte*2 + ($rnib eq "U" ? 1 : 0)}]
    puts "\n--- option $n : RX bank $rb byte${rbyte}${rnib} (bsc $rbsc), TX bank $tb byte$tbyte\
[expr {$score==0 ? {} : {   (same bank!)}}]"
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