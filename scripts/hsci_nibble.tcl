###############################################################################
##  hsci_nibble.tcl
##
##  Van part + package pin naar de FYSIEKE nibble: het BITSLICE_CONTROL-site
##  dat die pin klokt, plus de bitslice zelf, de XIPHY-byte-tile, de RIU_OR en
##  het PLL_SELECT_SITE.
##
##  Alles komt uit de device database, niets uit een naamregex. PIN_FUNC wordt
##  alleen gebruikt voor de QBC/DBC/GC-vlaggen en als kruiscontrole -- als de
##  device data en de pinnaam elkaar tegenspreken, staat dat in warnings.
##
##  Als library:
##      source scripts/hsci_nibble.tcl
##      hsci_nib_load_device xczu17eg-ffvd1760-1-e
##      set d [hsci_nibble_of_pin BB21]
##      dict get $d bsc_site        ;# BITSLICE_CONTROL_X0Y8  <- de fysieke nibble
##      dict get $d bsc             ;# 0  <- de N in de wizard-poort dly_rdy_bscN
##
##  Als script:
##      vivado -mode batch -source scripts/hsci_nibble.tcl \
##             -tclargs xczu17eg-ffvd1760-1-e BB21 AP18 AM16
##
##  Zonder pinnamen dumpt hij de nibble-indeling van elke HP bank.
###############################################################################

#=============================================================================
#  De structuur waar dit op rust, gemeten op xczu17eg-ffvd1760, Vivado 2025.1:
#
#  - Een HP bank heeft 52 IOB-sites = 4 byte groups x 13 bitslices.
#    get_sites -of_objects [get_iobanks <n>] geeft precies die 52.
#  - Per byte group bestaat een XIPHY_BYTE_*-tile met daarin 13 BITSLICE_RX_TX,
#    2 BITSLICE_CONTROL, 2 PLL_SELECT_SITE en 1 RIU_OR.
#  - De Y-nummering van BITSLICE_RX_TX is IDENTIEK aan die van de IOB-sites.
#    Gecontroleerd op alle vijf HP banks van dit package: bank 65 IOB Y 52..103
#    <-> bitslice Y 52..103, bank 66 104..155, 69 260..311, 70 312..363,
#    71 364..415. Daarom vind je de bitslice van een pin door in de
#    XIPHY-tiles van dezelfde clock region te zoeken naar dezelfde Y.
#  - Lage nibble = bitslice 0..5 van de byte group, hoge nibble = 6..12 (zeven,
#    want N12 hoort bij de hoge). Dat matcht PKGPIN_NIBBLE_INDEX.
#  - BITSLICE_CONTROL-Y loopt door over het hele device: byte0 van bank 65
#    krijgt Y8/Y9, byte1 Y10/Y11, byte2 Y12/Y13, byte3 Y14/Y15. Die Y is dus
#    het device-globale nibblenummer; de wizard nummert per instantie vanaf 0
#    (bsc0..bsc7 binnen de bank).
#=============================================================================

proc hsci_nib_fail {msg} {
    error "hsci_nibble: $msg"
}

# get_package_pins/get_sites geven NIETS terug in een kaal in-memory project;
# de device database wordt pas geladen door link_design. Geeft terug of wij
# het design zelf hebben aangemaakt.
proc hsci_nib_load_device {part} {
    if {[llength [current_project -quiet]] == 0} {
        create_project -in_memory -part $part
    }
    if {[llength [get_package_pins -quiet]] > 0} { return 0 }
    if {[llength [get_parts -quiet $part]] != 1} {
        hsci_nib_fail "part '$part' is niet bekend in deze Vivado-installatie --\
 controleer de spelling of installeer de device support"
    }
    if {[catch {link_design -part $part -name hsci_nibble} e]} {
        hsci_nib_fail "link_design faalde voor '$part': $e"
    }
    if {[llength [get_package_pins -quiet]] == 0} {
        hsci_nib_fail "link_design gelukt maar geen package pins -- is de device\
 support voor '$part' geinstalleerd?"
    }
    return 1
}

# Y-coordinaat uit een sitenaam: IOB_X0Y52 -> 52.
proc hsci_nib_site_y {site} {
    if {![regexp {Y(\d+)$} $site -> y]} {
        hsci_nib_fail "kan geen Y-coordinaat uit sitenaam '$site' halen"
    }
    return $y
}

# Sites van een type in een tile, gesorteerd op Y.
proc hsci_nib_sites_by_y {tile type} {
    set l [list]
    foreach s [get_sites -quiet -of_objects $tile -filter "SITE_TYPE == $type"] {
        lappend l [list [hsci_nib_site_y $s] $s]
    }
    set out [list]
    foreach e [lsort -integer -index 0 $l] { lappend out [lindex $e 1] }
    return $out
}

# Laagste IOB-Y van een bank. Gecached: dit is een query per bank.
proc hsci_nib_bank_base {bank} {
    global hsci_nib_base_cache
    if {[info exists hsci_nib_base_cache($bank)]} {
        return $hsci_nib_base_cache($bank)
    }
    set ys [list]
    foreach s [get_sites -quiet -of_objects [get_iobanks $bank]] {
        lappend ys [hsci_nib_site_y $s]
    }
    if {[llength $ys] == 0} { hsci_nib_fail "bank $bank heeft geen IOB-sites" }
    set base [lindex [lsort -integer $ys] 0]
    set hsci_nib_base_cache($bank) $base
    return $base
}

#-----------------------------------------------------------------------------
#  De hoofdproc. Geeft een dict met:
#
#    pin bank bank_type pin_func
#    iob            IOB-site van de pin
#    bitslice       BITSLICE_RX_TX-site van de pin
#    byte           byte group binnen de bank (0..3)
#    slice          bitslice binnen de byte group (0..12)
#    nibble         0 = lage (L), 1 = hoge (U)
#    nibble_letter  L of U
#    nibble_pos     positie binnen de nibble (0..6)
#    bsc            nibble binnen de bank (0..7) = byte*2 + nibble
#                   -> de N uit de wizard-poortnamen dly_rdy_bscN
#    bsc_site       BITSLICE_CONTROL-site: DE fysieke nibble
#    nibble_global  Y van dat site = device-globaal nibblenummer
#    riu_or         RIU_OR-site van de byte group
#    pll_select     PLL_SELECT_SITE van deze nibble
#    xiphy_tile     XIPHY_BYTE-tile van de byte group
#    hpio_tile      HPIO-tile van de pin
#    clock_region   clock region
#    clk_cap        QBC | DBC | {} -- kan de nibble-strobe klokken
#    is_gc          1 bij een global-clock-capable pin
#    warnings       afwijkingen tussen device data en PIN_FUNC/PKGPIN_*
#-----------------------------------------------------------------------------
proc hsci_nibble_of_pin {pin} {
    set pp [get_package_pins -quiet $pin]
    if {[llength $pp] != 1} {
        hsci_nib_fail "package pin '$pin' bestaat niet op dit package"
    }
    set func [get_property -quiet PIN_FUNC $pp]
    set bank [get_property -quiet BANK     $pp]

    set iob [get_sites -quiet -of_objects $pp]
    if {[llength $iob] != 1} {
        hsci_nib_fail "pin $pin ($func) heeft geen IO-site -- geen gebruikers-IO\
 (voeding, VREF, of niet gebond in dit package)"
    }
    if {![string match "IOB_*" $iob]} {
        hsci_nib_fail "pin $pin ($func) zit op site $iob, geen IOB -- dit is geen\
 SelectIO-pin (MGT, PS of config)"
    }

    set btype [get_property -quiet BANK_TYPE [get_iobanks $bank]]
    if {$btype ne "BT_HIGH_PERFORMANCE"} {
        hsci_nib_fail "pin $pin zit in bank $bank en dat is een $btype bank --\
 BITSLICE en nibbles bestaan alleen in HP banks (BT_HIGH_PERFORMANCE)"
    }

    set y     [hsci_nib_site_y $iob]
    set base  [hsci_nib_bank_base $bank]
    set ord   [expr {$y - $base}]
    set byte  [expr {$ord / 13}]
    set slice [expr {$ord % 13}]

    set hpio [get_tiles -quiet -of_objects $iob]
    set cr   [get_clock_regions -quiet -of_objects $hpio]

    # De XIPHY-tile van deze byte group: die met een BITSLICE_RX_TX op dezelfde
    # Y als onze IOB. Geen aanname over de volgorde van de tiles.
    set xiphy "" ; set bitslice ""
    foreach t [get_tiles -quiet -of_objects $cr -filter "TYPE =~ *XIPHY_BYTE*"] {
        foreach s [get_sites -quiet -of_objects $t -filter "SITE_TYPE == BITSLICE_RX_TX"] {
            if {[hsci_nib_site_y $s] == $y} { set xiphy $t ; set bitslice $s ; break }
        }
        if {$xiphy ne ""} break
    }
    if {$xiphy eq ""} {
        hsci_nib_fail "geen BITSLICE_RX_TX met Y=$y in de XIPHY-tiles van clock\
 region $cr -- op dit device geldt de aanname niet dat IOB en bitslice dezelfde\
 Y-nummering hebben"
    }

    set nibble     [expr {$slice < 6 ? 0 : 1}]
    set nibble_pos [expr {$slice - 6 * $nibble}]

    set bscs [hsci_nib_sites_by_y $xiphy BITSLICE_CONTROL]
    set plls [hsci_nib_sites_by_y $xiphy PLL_SELECT_SITE]
    if {[llength $bscs] != 2} {
        hsci_nib_fail "$xiphy heeft [llength $bscs] BITSLICE_CONTROL-sites,\
 verwacht 2 (een per nibble)"
    }
    set bsc_site [lindex $bscs $nibble]
    set pll_site [lindex $plls $nibble]
    set riu      [get_sites -quiet -of_objects $xiphy -filter "SITE_TYPE == RIU_OR"]

    # Kruiscontrole tegen PIN_FUNC en de PKGPIN_*-properties. De device data is
    # de waarheid; een afwijking betekent dat een aanname hierboven niet klopt.
    set warn [list]
    if {[regexp {_T(\d)([LU])_N(\d+)} $func -> f_byte f_nib f_slice]} {
        if {$f_byte != $byte} {
            lappend warn "PIN_FUNC zegt byte group $f_byte, device data zegt $byte"
        }
        if {[expr {$f_nib eq "U"}] != $nibble} {
            lappend warn "PIN_FUNC zegt nibble $f_nib, device data zegt\
 [expr {$nibble ? {U} : {L}}]"
        }
        if {$f_slice != $slice} {
            lappend warn "PIN_FUNC zegt N$f_slice, device data zegt N$slice"
        }
    }
    set pkg_bg  [get_property -quiet PKGPIN_BYTEGROUP_INDEX $pp]
    set pkg_nib [get_property -quiet PKGPIN_NIBBLE_INDEX    $pp]
    if {$pkg_bg ne "" && $pkg_bg != $slice} {
        lappend warn "PKGPIN_BYTEGROUP_INDEX is $pkg_bg, afgeleide slice is $slice"
    }
    if {$pkg_nib ne "" && $pkg_nib != $nibble_pos} {
        lappend warn "PKGPIN_NIBBLE_INDEX is $pkg_nib, afgeleide positie is $nibble_pos"
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

# Eenregelige samenvatting, voor lijsten.
proc hsci_nibble_line {d} {
    return [format "%-6s bank %-3s byte%s%s N%-2s bsc%-2s %-24s %-22s %s" \
        [dict get $d pin] [dict get $d bank] [dict get $d byte] \
        [dict get $d nibble_letter] [dict get $d slice] [dict get $d bsc] \
        [dict get $d bsc_site] [dict get $d bitslice] [dict get $d pin_func]]
}

# Volledig rapport voor een enkele pin.
proc hsci_nibble_report {d} {
    puts "\n  === [dict get $d pin] : [dict get $d pin_func] ==="
    foreach k {bank bank_type iob bitslice byte slice nibble_letter nibble_pos \
               bsc bsc_site nibble_global riu_or pll_select xiphy_tile \
               hpio_tile clock_region clk_cap is_gc} {
        puts [format "    %-14s %s" $k [dict get $d $k]]
    }
    foreach w [dict get $d warnings] { puts "    !! $w" }
}

# Alle pinnen van een bank, op fysieke volgorde.
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
#  CLI -- draait alleen als dit bestand zelf met -source is aangeroepen en er
#  -tclargs zijn. Source je het als library uit een script dat zelf -tclargs
#  krijgt, zet dan eerst:
#
#      set hsci_nibble_library 1
#      source [file join [file dirname [info script]] hsci_nibble.tcl]
#
#  anders zou de CLI hieronder op de argumenten van dat script losgaan.
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
