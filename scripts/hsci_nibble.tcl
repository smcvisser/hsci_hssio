###############################################################################
##  hsci_nibble.tcl
##
##  From part + package pin to the PHYSICAL nibble: the BITSLICE_CONTROL site
##  that clocks that pin, plus the bitslice itself, the XIPHY byte tile, the
##  RIU_OR and the PLL_SELECT_SITE.
##
##  Everything comes from the device database, nothing from a name regex.
##  PIN_FUNC is only used for the QBC/DBC/GC flags and as a cross-check -- if
##  the device data and the pin name contradict each other, it lands in
##  warnings.
##
##  As a library:
##      source scripts/hsci_nibble.tcl
##      hsci_nib_load_device xczu17eg-ffvd1760-1-e
##      set d [hsci_nibble_of_pin BB21]
##      dict get $d bsc_site        ;# BITSLICE_CONTROL_X0Y8  <- the physical nibble
##      dict get $d bsc             ;# 0  <- the N in the wizard port dly_rdy_bscN
##
##  As a script:
##      vivado -mode batch -source scripts/hsci_nibble.tcl \
##             -tclargs xczu17eg-ffvd1760-1-e BB21 AP18 AM16
##
##  Without pin names it dumps the nibble layout of every HP bank.
###############################################################################

#=============================================================================
#  The structure this rests on, measured on xczu17eg-ffvd1760, Vivado 2025.1:
#
#  - An HP bank has 52 IOB sites = 4 byte groups x 13 bitslices.
#    get_sites -of_objects [get_iobanks <n>] returns exactly those 52.
#  - Per byte group there is an XIPHY_BYTE_* tile containing 13
#    BITSLICE_RX_TX, 2 BITSLICE_CONTROL, 2 PLL_SELECT_SITE and 1 RIU_OR.
#  - The Y numbering of BITSLICE_RX_TX is IDENTICAL to that of the IOB sites.
#    Checked across all five HP banks of this package: bank 65 IOB Y 52..103
#    <-> bitslice Y 52..103, bank 66 104..155, 69 260..311, 70 312..363,
#    71 364..415. So you find the bitslice of a pin by searching the
#    XIPHY tiles of the same clock region for the same Y.
#  - Low nibble = bitslices 0..5 of the byte group, high nibble = 6..12
#    (seven, because N12 belongs to the high one). That matches
#    PKGPIN_NIBBLE_INDEX.
#  - BITSLICE_CONTROL Y runs on across the whole device: byte0 of bank 65
#    gets Y8/Y9, byte1 Y10/Y11, byte2 Y12/Y13, byte3 Y14/Y15. That Y is the
#    device-global nibble number; the wizard numbers from 0 per instance
#    (bsc0..bsc7 within the bank).
#=============================================================================

proc hsci_nib_fail {msg} {
    error "hsci_nibble: $msg"
}

# get_package_pins/get_sites return NOTHING in a bare in-memory project;
# the device database is only loaded by link_design. Returns whether we
# created the design ourselves.
proc hsci_nib_load_device {part} {
    if {[llength [current_project -quiet]] == 0} {
        create_project -in_memory -part $part
    }
    if {[llength [get_package_pins -quiet]] > 0} { return 0 }
    if {[llength [get_parts -quiet $part]] != 1} {
        hsci_nib_fail "part '$part' is not known in this Vivado installation --\
 check the spelling or install the device support"
    }
    if {[catch {link_design -part $part -name hsci_nibble} e]} {
        hsci_nib_fail "link_design failed for '$part': $e"
    }
    if {[llength [get_package_pins -quiet]] == 0} {
        hsci_nib_fail "link_design succeeded but no package pins -- is the device\
 support for '$part' installed?"
    }
    return 1
}

# Y coordinate from a site name: IOB_X0Y52 -> 52.
proc hsci_nib_site_y {site} {
    if {![regexp {Y(\d+)$} $site -> y]} {
        hsci_nib_fail "cannot get a Y coordinate from site name '$site'"
    }
    return $y
}

# Sites of one type in a tile, sorted by Y.
proc hsci_nib_sites_by_y {tile type} {
    set l [list]
    foreach s [get_sites -quiet -of_objects $tile -filter "SITE_TYPE == $type"] {
        lappend l [list [hsci_nib_site_y $s] $s]
    }
    set out [list]
    foreach e [lsort -integer -index 0 $l] { lappend out [lindex $e 1] }
    return $out
}

# Lowest IOB Y of a bank. Cached: this is one query per bank.
proc hsci_nib_bank_base {bank} {
    global hsci_nib_base_cache
    if {[info exists hsci_nib_base_cache($bank)]} {
        return $hsci_nib_base_cache($bank)
    }
    set ys [list]
    foreach s [get_sites -quiet -of_objects [get_iobanks $bank]] {
        lappend ys [hsci_nib_site_y $s]
    }
    if {[llength $ys] == 0} { hsci_nib_fail "bank $bank has no IOB sites" }
    set base [lindex [lsort -integer $ys] 0]
    set hsci_nib_base_cache($bank) $base
    return $base
}

#-----------------------------------------------------------------------------
#  The main proc. Returns a dict with:
#
#    pin bank bank_type pin_func
#    iob            IOB site of the pin
#    bitslice       BITSLICE_RX_TX site of the pin
#    byte           byte group within the bank (0..3)
#    slice          bitslice within the byte group (0..12)
#    nibble         0 = low (L), 1 = high (U)
#    nibble_letter  L or U
#    nibble_pos     position within the nibble (0..6)
#    bsc            nibble within the bank (0..7) = byte*2 + nibble
#                   -> the N from the wizard port names dly_rdy_bscN
#    bsc_site       BITSLICE_CONTROL site: THE physical nibble
#    nibble_global  Y of that site = device-global nibble number
#    riu_or         RIU_OR site of the byte group
#    pll_select     PLL_SELECT_SITE of this nibble
#    xiphy_tile     XIPHY_BYTE tile of the byte group
#    hpio_tile      HPIO tile of the pin
#    clock_region   clock region
#    clk_cap        QBC | DBC | {} -- can clock the nibble strobe
#    is_gc          1 on a global-clock-capable pin
#    warnings       discrepancies between device data and PIN_FUNC/PKGPIN_*
#-----------------------------------------------------------------------------
proc hsci_nibble_of_pin {pin} {
    set pp [get_package_pins -quiet $pin]
    if {[llength $pp] != 1} {
        hsci_nib_fail "package pin '$pin' does not exist on this package"
    }
    set func [get_property -quiet PIN_FUNC $pp]
    set bank [get_property -quiet BANK     $pp]

    set iob [get_sites -quiet -of_objects $pp]
    if {[llength $iob] != 1} {
        hsci_nib_fail "pin $pin ($func) has no IO site -- not user IO\
 (power, VREF, or not bonded in this package)"
    }
    if {![string match "IOB_*" $iob]} {
        hsci_nib_fail "pin $pin ($func) sits on site $iob, not an IOB -- this is not\
 a SelectIO pin (MGT, PS or config)"
    }

    set btype [get_property -quiet BANK_TYPE [get_iobanks $bank]]
    if {$btype ne "BT_HIGH_PERFORMANCE"} {
        hsci_nib_fail "pin $pin sits in bank $bank and that is a $btype bank --\
 BITSLICEs and nibbles only exist in HP banks (BT_HIGH_PERFORMANCE)"
    }

    set y     [hsci_nib_site_y $iob]
    set base  [hsci_nib_bank_base $bank]
    set ord   [expr {$y - $base}]
    set byte  [expr {$ord / 13}]
    set slice [expr {$ord % 13}]

    set hpio [get_tiles -quiet -of_objects $iob]
    set cr   [get_clock_regions -quiet -of_objects $hpio]

    # The XIPHY tile of this byte group: the one with a BITSLICE_RX_TX at the
    # same Y as our IOB. No assumption about the ordering of the tiles.
    set xiphy "" ; set bitslice ""
    foreach t [get_tiles -quiet -of_objects $cr -filter "TYPE =~ *XIPHY_BYTE*"] {
        foreach s [get_sites -quiet -of_objects $t -filter "SITE_TYPE == BITSLICE_RX_TX"] {
            if {[hsci_nib_site_y $s] == $y} { set xiphy $t ; set bitslice $s ; break }
        }
        if {$xiphy ne ""} break
    }
    if {$xiphy eq ""} {
        hsci_nib_fail "no BITSLICE_RX_TX with Y=$y in the XIPHY tiles of clock\
 region $cr -- on this device the assumption that IOB and bitslice share the\
 same Y numbering does not hold"
    }

    set nibble     [expr {$slice < 6 ? 0 : 1}]
    set nibble_pos [expr {$slice - 6 * $nibble}]

    set bscs [hsci_nib_sites_by_y $xiphy BITSLICE_CONTROL]
    set plls [hsci_nib_sites_by_y $xiphy PLL_SELECT_SITE]
    if {[llength $bscs] != 2} {
        hsci_nib_fail "$xiphy has [llength $bscs] BITSLICE_CONTROL sites,\
 expected 2 (one per nibble)"
    }
    set bsc_site [lindex $bscs $nibble]
    set pll_site [lindex $plls $nibble]
    set riu      [get_sites -quiet -of_objects $xiphy -filter "SITE_TYPE == RIU_OR"]

    # Cross-check against PIN_FUNC and the PKGPIN_* properties. The device
    # data is the truth; a discrepancy means an assumption above is wrong.
    set warn [list]
    if {[regexp {_T(\d)([LU])_N(\d+)} $func -> f_byte f_nib f_slice]} {
        if {$f_byte != $byte} {
            lappend warn "PIN_FUNC says byte group $f_byte, device data says $byte"
        }
        if {[expr {$f_nib eq "U"}] != $nibble} {
            lappend warn "PIN_FUNC says nibble $f_nib, device data says\
 [expr {$nibble ? {U} : {L}}]"
        }
        if {$f_slice != $slice} {
            lappend warn "PIN_FUNC says N$f_slice, device data says N$slice"
        }
    }
    set pkg_bg  [get_property -quiet PKGPIN_BYTEGROUP_INDEX $pp]
    set pkg_nib [get_property -quiet PKGPIN_NIBBLE_INDEX    $pp]
    if {$pkg_bg ne "" && $pkg_bg != $slice} {
        lappend warn "PKGPIN_BYTEGROUP_INDEX is $pkg_bg, derived slice is $slice"
    }
    if {$pkg_nib ne "" && $pkg_nib != $nibble_pos} {
        lappend warn "PKGPIN_NIBBLE_INDEX is $pkg_nib, derived position is $nibble_pos"
    }

    return [dict create \
        pin           $pin \
        bank          $bank \
        bank_type     $btype \
        pin_func      $func \
        iob           $iob \
        bitslice      $bitslice \
        byte          $byte \
        slice         $slice \
        nibble        $nibble \
        nibble_letter [expr {$nibble ? "U" : "L"}] \
        nibble_pos    $nibble_pos \
        bsc           [expr {$byte * 2 + $nibble}] \
        bsc_site      $bsc_site \
        nibble_global [hsci_nib_site_y $bsc_site] \
        riu_or        $riu \
        pll_select    $pll_site \
        xiphy_tile    $xiphy \
        hpio_tile     $hpio \
        clock_region  $cr \
        clk_cap       [lindex [regexp -inline {QBC|DBC} $func] 0] \
        is_gc         [regexp {_GC_} $func] \
        warnings      $warn]
}

# One-line summary, for lists.
proc hsci_nibble_line {d} {
    return [format "%-6s bank %-3s byte%s%s N%-2s bsc%-2s %-24s %-22s %s" \
        [dict get $d pin] [dict get $d bank] [dict get $d byte] \
        [dict get $d nibble_letter] [dict get $d slice] [dict get $d bsc] \
        [dict get $d bsc_site] [dict get $d bitslice] [dict get $d pin_func]]
}

# Full report for a single pin.
proc hsci_nibble_report {d} {
    puts "\n  === [dict get $d pin] : [dict get $d pin_func] ==="
    foreach k {bank bank_type iob bitslice byte slice nibble_letter nibble_pos \
               bsc bsc_site nibble_global riu_or pll_select xiphy_tile \
               hpio_tile clock_region clk_cap is_gc} {
        puts [format "    %-14s %s" $k [dict get $d $k]]
    }
    foreach w [dict get $d warnings] { puts "    !! $w" }
}

# All pins of a bank, in physical order.
proc hsci_nibble_dump_bank {bank} {
    puts "\n--- bank $bank"
    set rows [list]
    foreach s [get_sites -quiet -of_objects [get_iobanks $bank]] {
        lappend rows [list [hsci_nib_site_y $s] $s]
    }
    foreach e [lsort -integer -index 0 $rows] {
        set pp [get_package_pins -quiet -of_objects [lindex $e 1]]
        if {[llength $pp] != 1} { continue }
        if {[catch {hsci_nibble_of_pin [get_property NAME $pp]} d]} { continue }
        puts "  [hsci_nibble_line $d]"
    }
}

#=============================================================================
#  CLI -- runs only when this file itself is invoked with -source and there
#  are -tclargs. If you source it as a library from a script that itself gets
#  -tclargs, set first:
#
#      set hsci_nibble_library 1
#      source [file join [file dirname [info script]] hsci_nibble.tcl]
#
#  otherwise the CLI below would run loose on that script's arguments.
#=============================================================================
if {![info exists hsci_nibble_library] && [info exists argv] && [llength $argv] > 0} {
    set nib_part [lindex $argv 0]
    set nib_pins [lrange $argv 1 end]
    hsci_nib_load_device $nib_part
    puts "\n===== $nib_part ====="

    if {[llength $nib_pins] == 0} {
        foreach bank [get_iobanks -quiet] {
            if {[get_property -quiet BANK_TYPE [get_iobanks $bank]] ne "BT_HIGH_PERFORMANCE"} {
                continue
            }
            hsci_nibble_dump_bank $bank
        }
    } else {
        foreach p $nib_pins {
            if {[catch {hsci_nibble_of_pin $p} d]} {
                puts "\n  === $p ===\n    $d"
            } else {
                hsci_nibble_report $d
            }
        }
    }
    puts ""
}