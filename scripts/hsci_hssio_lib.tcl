###############################################################################
##  hsci_hssio_lib.tcl
##
##  The shared engine behind hsci_hssio_gen.tcl and the demo in demo/: part
##  and pin analysis, the rule checks, the port-map prediction and creating
##  the High Speed SelectIO Wizard instances.
##
##  Executes nothing itself -- only procs and the rate table. Source with:
##
##      source [file join [file dirname [info script]] hsci_hssio_lib.tcl]
##
##  Everything here is empirically verified on Vivado 2025.1 with wizard 3.6;
##  see docs/vivado-findings.md.
###############################################################################

#-----------------------------------------------------------------------------
# Maximum LVDS rate in NATIVE mode on HP banks, per speed grade.
#
#   Source: table "LVDS Native Mode Performance" in the device datasheet --
#   DS925 (Zynq US+), DS922 (Kintex US+), DS923 (Virtex US+).
#   Relevant row: RX DDR, RX_BITSLICE 1:8  (we do 8 bits per hsci_pclk).
#   The RX side is the binding one: TX reaches equal or more.
#
#   Native mode is the right table because the High Speed SelectIO Wizard
#   uses RX_BITSLICE/TX_BITSLICE + BITSLICE_CONTROL + XPLL. Component mode
#   (instantiating an ISERDESE3 yourself) is a different, lower path -- not
#   applicable here.
#
#   Careful when checking: 1250 Mb/s appears in two independent places in
#   the datasheet -- as the component-mode ceiling on -2/-3, and as the
#   native-mode ceiling on -1. Same number, different cause. So native is
#   NOT always 1600; on -1, native drops to 1250 too.
#
#   NOTE: these values are copied over, NOT queryable from Vivado.
#   Check them for your exact device and speed grade (incl. L variants).
#   cfg(force_rate) exists for the case where this table is too conservative
#   -- not to bypass a real limit.
#-----------------------------------------------------------------------------
array set MAX_RATE_HP_NATIVE {
    -1   1250
    -1L  1250
    -1LI 1250
    -1M  1250
    -1I  1250
    -2   1600
    -2L  1600
    -2I  1600
    -2LI 1600
    -3   1600
}

#=============================================================================
# 2. ERROR HANDLING
#=============================================================================

proc hsci_fail {reason {remedy ""}} {
    puts "\n**** HSCI CONFIGURATION IMPOSSIBLE ****\n"
    puts "  reason  : $reason"
    if {$remedy ne ""} { puts "  fix     : $remedy" }
    puts ""
    flush stdout
    error "HSCI: configuration impossible (see reason above)"
}

proc hsci_warn {msg} { puts "  WARNING: $msg" }

# get_package_pins and get_iobanks return NOTHING in a bare (in-memory)
# project -- the device database is only loaded by link_design. Returns
# whether we created the design ourselves, so we can close it again.
proc hsci_load_device {part} {
    if {[llength [get_package_pins -quiet]] > 0} { return 0 }
    puts "  loading device database (link_design)..."
    if {[catch {link_design -part $part -name hsci_pinquery} e]} {
        hsci_fail "cannot load the device database for '$part': $e" \
                  "get_package_pins/get_iobanks only work after link_design"
    }
    if {[llength [get_package_pins -quiet]] == 0} {
        hsci_fail "link_design succeeded but there are still no package pins" \
                  "is the device support for this part installed?"
    }
    return 1
}

#=============================================================================
# 3. PART ANALYSIS
#=============================================================================

# Everything we can get out of the part number.
proc hsci_part_info {part} {
    set p [get_parts -quiet $part]
    if {[llength $p] != 1} {
        hsci_fail "part '$part' is not known in this Vivado installation" \
                  "check the spelling, or install the device support"
    }
    set arch  [get_property -quiet ARCHITECTURE $p]
    set speed [get_property -quiet SPEED        $p]
    if {$speed eq ""} {
        # fallback: from the part name, e.g. xczu17eg-ffvc1760-2L-e
        if {[regexp {-([0-9][A-Za-z]*)-[A-Za-z]+$} $part -> s]} {
            set speed "-$s"
        } else {
            hsci_fail "cannot determine the speed grade from '$part'"
        }
    }
    return [dict create \
        part    $part \
        arch    $arch \
        family  [get_property -quiet FAMILY  $p] \
        device  [get_property -quiet DEVICE  $p] \
        package [get_property -quiet PACKAGE $p] \
        speed   $speed]
}

# Determines whether this device supports the High Speed SelectIO Wizard with
# BITSLICE.
proc hsci_check_arch {pi} {
    set arch [dict get $pi arch]
    if {[string match "versal*" $arch]} {
        hsci_fail "Versal ($arch) has no BITSLICE/HSSIO" \
                  "use advanced_io_wizard; see ADI's versal_hsci_phy.tcl for the config"
    }
    if {[string match "*uplus*" $arch]} { return "UltraScale+" }
    if {[regexp {^(kintexu|virtexu|zynqu)$} $arch]} {
        hsci_warn "$arch is UltraScale (not Plus). Byte groups and BITSLICE are the same,\
 but the maximum rate is lower -- check DS892/DS893."
        return "UltraScale"
    }
    hsci_fail "architecture '$arch' has no native-mode SelectIO with BITSLICE" \
              "this script only works on UltraScale / UltraScale+ HP banks"
}

# Hard gate on the requested data rate.
proc hsci_check_rate {pi rate force} {
    global MAX_RATE_HP_NATIVE
    set sg [dict get $pi speed]
    if {![info exists MAX_RATE_HP_NATIVE($sg)]} {
        hsci_warn "speed grade '$sg' is not in the table -- rate not checked.\
 Extend MAX_RATE_HP_NATIVE."
        return
    }
    set max $MAX_RATE_HP_NATIVE($sg)
    if {$rate <= $max} {
        puts "ok  $rate Mb/s fits within $max Mb/s for speed grade $sg"
        return
    }
    if {$force} {
        hsci_warn "$rate Mb/s > $max Mb/s for speed grade $sg, but force_rate=1 -- continuing"
        return
    }
    hsci_fail \
        "requested $rate Mb/s, but speed grade $sg of [dict get $pi device] reaches at\
 most $max Mb/s in native mode (HP bank, LVDS)" \
        "pick a faster speed grade, lower cfg(data_speed) to $max or below\
 (hsci_pclk then becomes [expr {$max/8.0}] MHz), or set cfg(force_rate) to 1 if you\
 have verified in the datasheet that the table is too conservative"
}

#=============================================================================
# 4. PIN ANALYSIS
#=============================================================================

# PIN_FUNC looks like:       IO_L16P_T2U_N6_QBC_AD3P_65
#                               ^pair  ^byte+nibble
#                                          ^index      ^bank
proc hsci_pin_info {pin} {
    set pp [get_package_pins -quiet $pin]
    if {[llength $pp] != 1} {
        hsci_fail "package pin '$pin' does not exist on this part" \
                  "check the pin name against the package file"
    }
    set func [get_property PIN_FUNC $pp]
    set bank [get_property BANK     $pp]

    if {![regexp {_T(\d)([LU])_N(\d+)} $func -> byte nib idx]} {
        hsci_fail "pin $pin ($func) does not belong to a byte group" \
                  "only pins in an HP byte group can do HSSIO; PS, HD and\
 config pins cannot"
    }
    if {![regexp {^IO_L(\d+)([PN])_} $func -> pair pn]} {
        hsci_fail "pin $pin ($func) is not a differential pin" \
                  "HSCI is LVDS; pick a pin from an L pair"
    }

    # QBC and DBC are not the same, and the difference determines how far the
    # strobe reaches (UG571, "Clocking" in the SelectIO chapter):
    #
    #   DBC  dual byte clock  -- clocks the two nibbles of its OWN byte group
    #   QBC  quad byte clock  -- clocks four nibbles, so the adjacent byte
    #                            group too
    #
    # So strobe and data do NOT have to be in the same nibble; the same byte
    # group is enough. If the strobe is in the other nibble than the data, the
    # instance gets two BITSLICE_CONTROLs (one per nibble) and thus two sets
    # of bsc ports.
    set clkcap ""
    if {[regexp {_(QBC|DBC)_} $func -> c]} { set clkcap $c }

    return [dict create \
        pin $pin  func $func  bank $bank \
        byte $byte  nibl $nib  idx $idx  pair $pair  pn $pn \
        nib   [expr {$nib eq "U" ? 1 : 0}] \
        bsc   [expr {$byte * 2 + ($nib eq "U" ? 1 : 0)}] \
        slice [expr {$byte * 13 + $idx}] \
        clkcap $clkcap]
}

# The RX rule. Strobe and data must be in the same byte group of the same
# bank, and the strobe on a DBC or QBC pin (the N0/N1 or N6/N7 pairs). If
# they are in different nibbles, the strobe must be able to reach the other
# nibble -- which a DBC or QBC pin can do by definition within its own byte
# group.
#
# Returns the list of BITSLICE_CONTROL indices the RX instance will produce,
# ascending.
proc hsci_check_rx_group {clkp datp} {
    if {[dict get $clkp bank] != [dict get $datp bank]} {
        hsci_fail "RX data is in bank [dict get $datp bank] and the strobe in bank\
 [dict get $clkp bank]" \
                  "strobe and data must be in the same byte group of the same bank"
    }
    if {[dict get $clkp byte] != [dict get $datp byte]} {
        hsci_fail "RX strobe is in byte group [dict get $clkp byte] and the data in\
 [dict get $datp byte]" \
                  "a DBC pin only clocks the nibbles of its own byte group;\
 put strobe and data in the same byte group"
    }
    if {[dict get $clkp clkcap] eq ""} {
        hsci_fail "RX strobe [dict get $clkp pin] is not a QBC/DBC pin\
 ([dict get $clkp func])" \
                  "the strobe must be on the N0/N1 or N6/N7 pair of a nibble; those\
 are marked DBC or QBC in the pin name"
    }
    if {[dict get $clkp idx] != 0 && [dict get $clkp idx] != 6} {
        hsci_fail "RX strobe sits on N[dict get $clkp idx]" \
                  "the P side of a DBC/QBC pair is N0 or N6"
    }
    return [lsort -unique -integer [list [dict get $clkp bsc] [dict get $datp bsc]]]
}

proc hsci_fmt {d} {
    return [format "%-6s bank %-3s byte%s%s N%-2s bsc%-2s slice%-3s %s" \
        [dict get $d pin]  [dict get $d bank] [dict get $d byte] \
        [dict get $d nibl] [dict get $d idx]  [dict get $d bsc]  \
        [dict get $d slice] [dict get $d func]]
}

proc hsci_check_pair {label p n} {
    foreach {k what} {bank "bank" byte "byte group" nib "nibble" pair "L pair"} {
        if {[dict get $p $k] != [dict get $n $k]} {
            hsci_fail "$label: [dict get $p pin] and [dict get $n pin] are not in\
 the same $what, so they do not form a differential pair" \
                      "use the P and N side of one and the same L pair"
        }
    }
    if {[dict get $p pn] ne "P" || [dict get $n pn] ne "N"} {
        hsci_fail "$label: P/N swapped -- [dict get $p pin] is the\
 [dict get $p pn] side, [dict get $n pin] the [dict get $n pn] side" \
                  "swap the two pins in the config"
    }
}

proc hsci_check_bank_hp {bank what} {
    set b [get_iobanks -quiet $bank]
    if {$b eq ""} { hsci_fail "bank $bank does not exist on this package" }
    set t [get_property BANK_TYPE $b]
    if {$t ne "BT_HIGH_PERFORMANCE"} {
        hsci_fail "$what is in bank $bank, and that is a $t bank" \
                  "BITSLICE/HSSIO only exists in HP banks (BT_HIGH_PERFORMANCE);\
 move the signals to an HP bank"
    }
}

# Complete pin table of a bank: byte,idx -> {pin name pin_func}
proc hsci_bank_pin_table {bank} {
    set tbl [dict create]
    foreach pp [get_package_pins -quiet -filter "BANK == $bank"] {
        set func [get_property PIN_FUNC $pp]
        if {![regexp {_T(\d)([LU])_N(\d+)} $func -> byte nib idx]} { continue }
        dict set tbl $byte,$idx [list [get_property NAME $pp] $func]
    }
    return $tbl
}

#=============================================================================
# 5. PREDICT THE PORT MAP
#
#  Derived from ADI's working vcu118 combination (system_project.tcl config
#  <-> hsci_phy_top.sv instantiation). The rules:
#
#    pad port             = SIGNAL_NAME                    (APPEND_PIN_NO=0)
#    fabric port TX       = data_from_fabric_<SIGNAL_NAME>
#    fabric port RX       = data_to_fabric_<SIGNAL_NAME>
#    bitslice control     = {dly_rdy,vtc_rdy,en_vtc}_bsc<byte*2 + nibble>
#    per-bitslice FIFO    = {fifo_rd_clk,fifo_rd_en,fifo_empty}_<byte*13 + idx>
#    PLL / reset          = clk, rst, pll0_locked, pll0_clkout0, rst_seq_done
#
#  Check against ADI: byte2 pin6 -> slice 32, pin8 -> slice 34 (matches their
#  fifo_rd_en_34), byte0 nib0 -> bsc0, byte0 nib1 -> bsc1, byte2 nib1 -> bsc5.
#
#  This prediction is later machine-checked against the .veo template.
#=============================================================================

#  The signal names are configurable because they come from
#  CONFIG.BYTE?_PIN?_SIGNAL_NAME: the generator uses data_out_p/clk_out_p, the
#  demo hsci_mosi_d_p and hsci_mosi_clk_p. The defaults keep existing callers
#  intact.
proc hsci_predict_tx {bsc_list {dat_p data_out_p} {dat_n data_out_n}
                      {clk_p clk_out_p} {clk_n clk_out_n}} {
    set p [list clk rst pll0_locked pll0_clkout0 rst_seq_done \
                $dat_p $dat_n data_from_fabric_$dat_p \
                $clk_p $clk_n data_from_fabric_$clk_p]
    foreach b $bsc_list { lappend p dly_rdy_bsc$b vtc_rdy_bsc$b en_vtc_bsc$b }
    return $p
}

# bsc_list is a list: if the strobe is in the other nibble than the data, the
# wizard produces two BITSLICE_CONTROLs.
proc hsci_predict_rx {bsc_list slice_c slice_d {clk_p clk_in_p} {clk_n clk_in_n}
                      {dat_p data_in_p} {dat_n data_in_n}} {
    set p [list clk rst pll0_locked pll0_clkout0 rst_seq_done \
                $clk_p $clk_n data_to_fabric_$clk_p \
                $dat_p $dat_n data_to_fabric_$dat_p]
    foreach b $bsc_list { lappend p dly_rdy_bsc$b vtc_rdy_bsc$b en_vtc_bsc$b }
    foreach s [list $slice_c $slice_d] {
        lappend p fifo_rd_clk_$s fifo_rd_en_$s fifo_empty_$s
    }
    return $p
}

#=============================================================================
# 6. IP HELPERS
#=============================================================================

proc hsci_pin_props {byte idx signame {strobe ""} {busdir ""} {init ""}} {
    set l [list]
    lappend l CONFIG.ENABLE_BYTE${byte}_PIN${idx}      {true}
    lappend l CONFIG.BYTE${byte}_PIN${idx}_SIGNAL_NAME $signame
    lappend l CONFIG.BYTE${byte}_PIN${idx}_SIG_TYPE    {DIFF}
    if {$strobe ne ""} { lappend l CONFIG.BYTE${byte}_PIN${idx}_DATA_STROBE $strobe }
    if {$busdir ne ""} { lappend l CONFIG.BYTE${byte}_PIN${idx}_BUS_DIR     $busdir }
    if {$init   ne ""} { lappend l CONFIG.BYTE${byte}_PIN${idx}_INIT        $init   }
    return $l
}

# Set LOC + NAME for all 13 pins of every byte group we touch, like ADI does.
# Prevents dependence on derivation from BANK.
proc hsci_bytegroup_props {bank bytes} {
    set tbl [hsci_bank_pin_table $bank]
    set l [list]
    foreach byte $bytes {
        for {set i 0} {$i < 13} {incr i} {
            if {![dict exists $tbl $byte,$i]} { continue }
            lassign [dict get $tbl $byte,$i] pname pfunc
            lappend l CONFIG.BYTE${byte}_PIN${i}_LOC  $pname
            lappend l CONFIG.BYTE${byte}_PIN${i}_NAME $pfunc
        }
    }
    return $l
}

# Builds "disable every pin we don't use". By default the wizard has
# BYTE2_PIN0 (signal name 'clk', clashes with the IP clock) and BYTE3_PIN12
# enabled; leave them on and validation fails with messages about byte groups
# you never touched. ADI does this explicitly too.
proc hsci_disable_unused {ip keep} {
    set l [list]
    foreach p [lsearch -all -inline -glob [list_property $ip] CONFIG.ENABLE_BYTE?_PIN*] {
        if {![regexp {ENABLE_BYTE(\d)_PIN(\d+)$} $p -> b i]} { continue }
        if {[lsearch -exact $keep "$b,$i"] >= 0} { continue }
        lappend l $p {false}
    }
    return $l
}

# Properties the wizard declares "disabled" in certain modes are silently
# ignored: set_property succeeds, only a "[IP_Flow 19-3374] ... has been
# ignored" WARNING goes by, and you end up with an IP that does something
# other than what you wrote down. So we read everything back.
#
# These may differ and are not an error:
#   PLL0_PLLOUT0       always derived from data_speed (= data_speed/8)
#   ENABLE_N_PINS      doesn't exist in TX_ONLY mode
#   TX_PRE_EMPHASIS_D  only visible in some modes
proc hsci_verify_props {name ip props} {
    set soft {CONFIG.PLL0_PLLOUT0 CONFIG.ENABLE_N_PINS CONFIG.TX_PRE_EMPHASIS_D}
    set hard [list] ; set warn [list]
    foreach {k v} $props {
        set got [get_property -quiet $k $ip]
        if {$got eq $v} { continue }
        if {[string is double -strict $v] && [string is double -strict $got]
            && abs($got - $v) < 0.001} { continue }
        set msg "$k : requested '$v', wizard kept '$got'"
        if {[lsearch -exact $soft $k] >= 0} { lappend warn $msg } else { lappend hard $msg }
    }
    foreach m $warn { hsci_warn "$name: $m (derived by the wizard, not a problem)" }
    if {[llength $hard]} {
        hsci_fail "the wizard ignored [llength $hard] property/properties of '$name':\n            [join $hard "\n            "]" \
                  "an ignored property means it is disabled in this mode --\
 usually CONFIG.BUS_DIR is wrong (0=TX_ONLY, 1=RX_ONLY, 3=TX+RX, 2=BIDIR)"
    }
}

proc hsci_create_ip {name props keep} {
    if {[llength [get_ips -quiet $name]]} {
        puts "  -- replacing existing IP '$name'"
        remove_files [get_files -quiet ${name}.xci]
    }
    # Don't pin the version. On Vivado 2025.1 and 2026.1 it is 3.6, same as ADI.
    create_ip -name high_speed_selectio_wiz -vendor xilinx.com -library ip \
              -module_name $name
    set ip [get_ips $name]

    # Everything in ONE set_property -dict. Property by property doesn't work:
    # the wizard validates after each individual property and trips over an
    # inconsistent intermediate state (pin enabled while its BUS_DIR is still
    # at the default RX -> "RX and TX cannot be combined in same nibble").
    set full [concat [hsci_disable_unused $ip $keep] $props]
    if {[catch {set_property -dict $full $ip} err]} {
        hsci_fail "the wizard refuses this configuration for '$name':\n            $err" \
                  "the wizard message above usually names the exact rule\
 (nibble layout, strobe position, port name clash)"
    }

    # Rate feedback: if the wizard clamps, we know the part can't do it.
    set got [get_property -quiet CONFIG.PLL0_DATA_SPEED $ip]
    set want [dict get [dict create {*}$props] CONFIG.PLL0_DATA_SPEED]
    if {$got ne "" && [expr {abs($got - $want)}] > 0.01} {
        hsci_fail "wizard clamped PLL0_DATA_SPEED from $want to $got Mb/s" \
                  "this part doesn't reach the requested rate; lower cfg(data_speed) to $got"
    }

    hsci_verify_props $name $ip $props
    return $ip
}

proc hsci_veo_ports {ip} {
    set f [get_files -quiet -all "*${ip}.veo"]
    if {[llength $f] == 0} {
        set dir [get_property -quiet IP_DIR [get_ips $ip]]
        if {$dir ne ""} { set f [glob -nocomplain -directory $dir *.veo] }
    }
    set f [lsearch -all -inline -glob $f "*.veo"]
    if {[llength $f] == 0 || ![file readable [lindex $f 0]]} { return {} }
    set fh [open [lindex $f 0] r]
    set txt [read $fh]
    close $fh
    set ports [list]
    foreach {all p} [regexp -all -inline {\.([A-Za-z_][A-Za-z0-9_]*)\s*\(} $txt] {
        lappend ports $p
    }
    return [lsort -unique $ports]
}

proc hsci_check_ports {ip wanted} {
    set have [hsci_veo_ports $ip]
    if {[llength $have] == 0} {
        hsci_warn "no .veo found for $ip -- port names NOT verified"
        return 0
    }
    set miss [list]
    foreach p $wanted { if {[lsearch -exact $have $p] < 0} { lappend miss $p } }
    if {[llength $miss] == 0} {
        puts "  ok $ip : all [llength $wanted] predicted ports exist"
        return 1
    }
    puts "  !! $ip : [llength $miss] predicted port(s) do NOT exist:"
    foreach p $miss { puts "       $p" }
    puts "     wizard offers: [join $have {, }]"
    return 0
}

#=============================================================================