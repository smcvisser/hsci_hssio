###############################################################################
##  hsci_hssio_lib.tcl
##
##  De gedeelde motor achter hsci_hssio_gen.tcl en de demo in demo/: part- en
##  pin-analyse, de regelchecks, de port-map-voorspelling en het aanmaken van
##  de High Speed SelectIO Wizard instanties.
##
##  Zelf niets uitvoeren -- alleen procs en de rate-tabel. Sourcen met:
##
##      source [file join [file dirname [info script]] hsci_hssio_lib.tcl]
##
##  Alles wat hier staat is empirisch getoetst op Vivado 2025.1 met wizard 3.6;
##  zie docs/vivado-bevindingen.md.
###############################################################################

#-----------------------------------------------------------------------------
# Maximale LVDS rate in NATIVE mode op HP banks, per speed grade.
#
#   Bron: tabel "LVDS Native Mode Performance" in de device datasheet --
#   DS925 (Zynq US+), DS922 (Kintex US+), DS923 (Virtex US+).
#   Relevante rij: RX DDR, RX_BITSLICE 1:8  (wij doen 8 bits per hsci_pclk).
#   De RX-kant is de bindende: TX haalt gelijk of meer.
#
#   Native mode is de juiste tabel omdat de High Speed SelectIO Wizard
#   RX_BITSLICE/TX_BITSLICE + BITSLICE_CONTROL + XPLL gebruikt. Component mode
#   (zelf een ISERDESE3 instantieren) is een ander, lager pad -- niet van
#   toepassing hier.
#
#   Pas op bij het naslaan: 1250 Mb/s staat op twee onafhankelijke plekken in
#   de datasheet -- als component-mode plafond bij -2/-3, en als native-mode
#   plafond bij -1. Zelfde getal, andere oorzaak. Native is dus NIET altijd
#   1600; op -1 zakt ook native naar 1250.
#
#   LET OP: deze waarden zijn overgeschreven, NIET opvraagbaar uit Vivado.
#   Controleer ze voor jouw exacte device en speed grade (incl. L-varianten).
#   cfg(force_rate) is bedoeld voor het geval deze tabel te conservatief is --
#   niet om een echte limiet te omzeilen.
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
# 2. FOUTAFHANDELING
#=============================================================================

proc hsci_fail {reden {remedie ""}} {
    puts "\n**** HSCI CONFIGURATIE ONMOGELIJK ****\n"
    puts "  reden   : $reden"
    if {$remedie ne ""} { puts "  remedie : $remedie" }
    puts ""
    flush stdout
    error "HSCI: configuratie onmogelijk (zie reden hierboven)"
}

proc hsci_warn {msg} { puts "  WAARSCHUWING: $msg" }

# get_package_pins en get_iobanks geven NIETS terug in een kaal (in-memory)
# project -- de device database wordt pas geladen door link_design. Geeft terug
# of wij het design zelf hebben aangemaakt, zodat we het weer kunnen sluiten.
proc hsci_load_device {part} {
    if {[llength [get_package_pins -quiet]] > 0} { return 0 }
    puts "  device database laden (link_design)..."
    if {[catch {link_design -part $part -name hsci_pinquery} e]} {
        hsci_fail "kan de device database niet laden voor '$part': $e" \
                  "get_package_pins/get_iobanks werken pas na link_design"
    }
    if {[llength [get_package_pins -quiet]] == 0} {
        hsci_fail "link_design gelukt maar er zijn nog steeds geen package pins" \
                  "is de device support voor dit part geinstalleerd?"
    }
    return 1
}

#=============================================================================
# 3. PART-ANALYSE
#=============================================================================

# Alles wat we uit het part-nummer kunnen halen.
proc hsci_part_info {part} {
    set p [get_parts -quiet $part]
    if {[llength $p] != 1} {
        hsci_fail "part '$part' is niet bekend in deze Vivado-installatie" \
                  "controleer de spelling, of installeer de device support"
    }
    set arch  [get_property -quiet ARCHITECTURE $p]
    set speed [get_property -quiet SPEED        $p]
    if {$speed eq ""} {
        # fallback: uit de partnaam, bv xczu17eg-ffvc1760-2L-e
        if {[regexp {-([0-9][A-Za-z]*)-[A-Za-z]+$} $part -> s]} {
            set speed "-$s"
        } else {
            hsci_fail "kan de speed grade niet bepalen uit '$part'"
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

# Bepaalt of dit device de High Speed SelectIO Wizard met BITSLICE ondersteunt.
proc hsci_check_arch {pi} {
    set arch [dict get $pi arch]
    if {[string match "versal*" $arch]} {
        hsci_fail "Versal ($arch) heeft geen BITSLICE/HSSIO" \
                  "gebruik advanced_io_wizard; zie ADI's versal_hsci_phy.tcl voor de config"
    }
    if {[string match "*uplus*" $arch]} { return "UltraScale+" }
    if {[regexp {^(kintexu|virtexu|zynqu)$} $arch]} {
        hsci_warn "$arch is UltraScale (niet Plus). Byte groups en BITSLICE zijn gelijk,\
 maar de maximale rate ligt lager -- controleer DS892/DS893."
        return "UltraScale"
    }
    hsci_fail "architectuur '$arch' heeft geen native-mode SelectIO met BITSLICE" \
              "dit script werkt alleen op UltraScale / UltraScale+ HP banks"
}

# Harde gate op de gevraagde datarate.
proc hsci_check_rate {pi rate force} {
    global MAX_RATE_HP_NATIVE
    set sg [dict get $pi speed]
    if {![info exists MAX_RATE_HP_NATIVE($sg)]} {
        hsci_warn "speed grade '$sg' staat niet in de tabel -- rate niet gecontroleerd.\
 Vul MAX_RATE_HP_NATIVE aan."
        return
    }
    set max $MAX_RATE_HP_NATIVE($sg)
    if {$rate <= $max} {
        puts "ok  $rate Mb/s past binnen $max Mb/s voor speed grade $sg"
        return
    }
    if {$force} {
        hsci_warn "$rate Mb/s > $max Mb/s voor speed grade $sg, maar force_rate=1 -- doorgaan"
        return
    }
    hsci_fail \
        "gevraagd $rate Mb/s, maar speed grade $sg van [dict get $pi device] haalt in\
 native mode maximaal $max Mb/s (HP bank, LVDS)" \
        "kies een snellere speed grade, verlaag cfg(data_speed) naar $max of lager\
 (hsci_pclk wordt dan [expr {$max/8.0}] MHz), of zet cfg(force_rate) op 1 als je\
 in de datasheet hebt geverifieerd dat de tabel te conservatief is"
}

#=============================================================================
# 4. PIN-ANALYSE
#=============================================================================

# PIN_FUNC ziet er uit als:  IO_L16P_T2U_N6_QBC_AD3P_65
#                               ^pair  ^byte+nibble
#                                          ^index      ^bank
proc hsci_pin_info {pin} {
    set pp [get_package_pins -quiet $pin]
    if {[llength $pp] != 1} {
        hsci_fail "package pin '$pin' bestaat niet op dit part" \
                  "controleer de pinnaam tegen het package file"
    }
    set func [get_property PIN_FUNC $pp]
    set bank [get_property BANK     $pp]

    if {![regexp {_T(\d)([LU])_N(\d+)} $func -> byte nib idx]} {
        hsci_fail "pin $pin ($func) hoort niet bij een byte group" \
                  "alleen pinnen in een HP byte group kunnen HSSIO doen; PS-, HD- en\
 config-pinnen niet"
    }
    if {![regexp {^IO_L(\d+)([PN])_} $func -> pair pn]} {
        hsci_fail "pin $pin ($func) is geen differentieel pin" \
                  "HSCI is LVDS; kies een pin uit een L-paar"
    }

    # QBC en DBC zijn niet hetzelfde, en het verschil bepaalt hoe ver de strobe
    # reikt (UG571, "Clocking" in het SelectIO-hoofdstuk):
    #
    #   DBC  dual byte clock  -- klokt de twee nibbles van zijn EIGEN byte group
    #   QBC  quad byte clock  -- klokt vier nibbles, dus ook de aangrenzende
    #                            byte group
    #
    # Strobe en data hoeven dus NIET in dezelfde nibble te zitten; dezelfde
    # byte group is genoeg. Zit de strobe in de andere nibble dan de data, dan
    # krijgt de instantie twee BITSLICE_CONTROLs (een per nibble) en dus twee
    # sets bsc-poorten.
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

# De RX-regel. Strobe en data moeten in dezelfde byte group van dezelfde bank,
# en de strobe op een DBC- of QBC-pin (de N0/N1- of N6/N7-paren). Zitten ze in
# verschillende nibbles, dan moet de strobe de andere nibble kunnen bereiken --
# wat een DBC- of QBC-pin per definitie kan binnen zijn eigen byte group.
#
# Geeft de lijst BITSLICE_CONTROL-indices terug die de RX-instantie zal
# opleveren, oplopend.
proc hsci_check_rx_group {clkp datp} {
    if {[dict get $clkp bank] != [dict get $datp bank]} {
        hsci_fail "RX data zit in bank [dict get $datp bank] en de strobe in bank\
 [dict get $clkp bank]" \
                  "strobe en data moeten in dezelfde byte group van dezelfde bank"
    }
    if {[dict get $clkp byte] != [dict get $datp byte]} {
        hsci_fail "RX strobe zit in byte group [dict get $clkp byte] en de data in\
 [dict get $datp byte]" \
                  "een DBC-pin klokt alleen de nibbles van zijn eigen byte group;\
 zet strobe en data in dezelfde byte group"
    }
    if {[dict get $clkp clkcap] eq ""} {
        hsci_fail "RX strobe [dict get $clkp pin] is geen QBC/DBC pin\
 ([dict get $clkp func])" \
                  "de strobe moet op het N0/N1- of N6/N7-paar van een nibble; die zijn\
 als DBC of QBC gemarkeerd in de pinnaam"
    }
    if {[dict get $clkp idx] != 0 && [dict get $clkp idx] != 6} {
        hsci_fail "RX strobe staat op N[dict get $clkp idx]" \
                  "de P-kant van een DBC/QBC paar is N0 of N6"
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
    foreach {k wat} {bank "bank" byte "byte group" nib "nibble" pair "L-paar"} {
        if {[dict get $p $k] != [dict get $n $k]} {
            hsci_fail "$label: [dict get $p pin] en [dict get $n pin] zitten niet in\
 hetzelfde $wat, dus vormen geen differentieel paar" \
                      "gebruik de P- en N-kant van een en hetzelfde L-paar"
        }
    }
    if {[dict get $p pn] ne "P" || [dict get $n pn] ne "N"} {
        hsci_fail "$label: P/N verwisseld -- [dict get $p pin] is de\
 [dict get $p pn]-kant, [dict get $n pin] de [dict get $n pn]-kant" \
                  "draai de twee pinnen om in de config"
    }
}

proc hsci_check_bank_hp {bank wat} {
    set b [get_iobanks -quiet $bank]
    if {$b eq ""} { hsci_fail "bank $bank bestaat niet op dit package" }
    set t [get_property BANK_TYPE $b]
    if {$t ne "BT_HIGH_PERFORMANCE"} {
        hsci_fail "$wat zit in bank $bank, en dat is een $t bank" \
                  "BITSLICE/HSSIO bestaat alleen in HP banks (BT_HIGH_PERFORMANCE);\
 verplaats de signalen naar een HP bank"
    }
}

# Volledige pin-tabel van een bank: byte,idx -> {pinnaam pin_func}
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
# 5. PORT MAP VOORSPELLEN
#
#  Afgeleid uit ADI's werkende vcu118-combinatie (system_project.tcl config
#  <-> hsci_phy_top.sv instantiatie). De regels:
#
#    pad-poort            = SIGNAL_NAME                    (APPEND_PIN_NO=0)
#    fabric-poort TX      = data_from_fabric_<SIGNAL_NAME>
#    fabric-poort RX      = data_to_fabric_<SIGNAL_NAME>
#    bitslice control     = {dly_rdy,vtc_rdy,en_vtc}_bsc<byte*2 + nibble>
#    per-bitslice FIFO    = {fifo_rd_clk,fifo_rd_en,fifo_empty}_<byte*13 + idx>
#    PLL / reset          = clk, rst, pll0_locked, pll0_clkout0, rst_seq_done
#
#  Controle op ADI: byte2 pin6 -> slice 32, pin8 -> slice 34 (klopt met hun
#  fifo_rd_en_34), byte0 nib0 -> bsc0, byte0 nib1 -> bsc1, byte2 nib1 -> bsc5.
#
#  Deze voorspelling wordt verderop machinaal getoetst aan de .veo template.
#=============================================================================

#  De signaalnamen zijn instelbaar omdat ze uit CONFIG.BYTE?_PIN?_SIGNAL_NAME
#  komen: de generator gebruikt data_out_p/clk_out_p, de demo hsci_mosi_d_p en
#  hsci_mosi_clk_p. De defaults houden de bestaande aanroepen intact.
proc hsci_predict_tx {bsc_list {dat_p data_out_p} {dat_n data_out_n}
                      {clk_p clk_out_p} {clk_n clk_out_n}} {
    set p [list clk rst pll0_locked pll0_clkout0 rst_seq_done \
                $dat_p $dat_n data_from_fabric_$dat_p \
                $clk_p $clk_n data_from_fabric_$clk_p]
    foreach b $bsc_list { lappend p dly_rdy_bsc$b vtc_rdy_bsc$b en_vtc_bsc$b }
    return $p
}

# bsc_list is een lijst: zit de strobe in de andere nibble dan de data, dan
# levert de wizard twee BITSLICE_CONTROLs op.
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
# 6. IP-HELPERS
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

# Zet LOC + NAME voor alle 13 pinnen van elke byte group die we aanraken,
# zoals ADI doet. Voorkomt dat we afhankelijk zijn van afleiding uit BANK.
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

# Bouwt "zet elke pin uit die wij niet gebruiken". De wizard heeft standaard
# BYTE2_PIN0 (signaalnaam 'clk', botst met de IP-klok) en BYTE3_PIN12 aan
# staan; laat je die staan, dan faalt de validatie met meldingen over byte
# groups die je nooit hebt aangeraakt. ADI doet dit ook expliciet.
proc hsci_disable_unused {ip keep} {
    set l [list]
    foreach p [lsearch -all -inline -glob [list_property $ip] CONFIG.ENABLE_BYTE?_PIN*] {
        if {![regexp {ENABLE_BYTE(\d)_PIN(\d+)$} $p -> b i]} { continue }
        if {[lsearch -exact $keep "$b,$i"] >= 0} { continue }
        lappend l $p {false}
    }
    return $l
}

# Properties die de wizard in bepaalde modi "disabled" verklaart, worden
# STILZWIJGEND genegeerd: set_property slaagt, er komt alleen een
# "[IP_Flow 19-3374] ... has been ignored" WARNING voorbij, en je houdt een IP
# over dat iets anders doet dan je hebt opgeschreven. Daarom lezen we alles
# terug.
#
# Deze twee mogen afwijken en zijn geen fout:
#   PLL0_PLLOUT0   wordt altijd afgeleid uit data_speed (= data_speed/8)
#   ENABLE_N_PINS  bestaat niet in TX_ONLY-modus
#   TX_PRE_EMPHASIS_D  alleen zichtbaar in sommige modi
proc hsci_verify_props {name ip props} {
    set soft {CONFIG.PLL0_PLLOUT0 CONFIG.ENABLE_N_PINS CONFIG.TX_PRE_EMPHASIS_D}
    set hard [list] ; set warn [list]
    foreach {k v} $props {
        set got [get_property -quiet $k $ip]
        if {$got eq $v} { continue }
        if {[string is double -strict $v] && [string is double -strict $got]
            && abs($got - $v) < 0.001} { continue }
        set msg "$k : gevraagd '$v', wizard hield '$got'"
        if {[lsearch -exact $soft $k] >= 0} { lappend warn $msg } else { lappend hard $msg }
    }
    foreach m $warn { hsci_warn "$name: $m (afgeleid door de wizard, niet erg)" }
    if {[llength $hard]} {
        hsci_fail "de wizard heeft [llength $hard] property/properties van '$name'\
 genegeerd:\n            [join $hard "\n            "]" \
                  "een genegeerde property betekent dat hij in deze modus disabled is --\
 meestal klopt CONFIG.BUS_DIR niet (0=TX_ONLY, 1=RX_ONLY, 3=TX+RX, 2=BIDIR)"
    }
}

proc hsci_create_ip {name props keep} {
    if {[llength [get_ips -quiet $name]]} {
        puts "  -- bestaande IP '$name' wordt vervangen"
        remove_files [get_files -quiet ${name}.xci]
    }
    # Versie niet pinnen. Op Vivado 2025.1 en 2026.1 is het 3.6, gelijk aan ADI.
    create_ip -name high_speed_selectio_wiz -vendor xilinx.com -library ip \
              -module_name $name
    set ip [get_ips $name]

    # Alles in EEN set_property -dict. Property-voor-property werkt niet: de
    # wizard valideert na elke losse property en struikelt dan over een
    # inconsistente tussentoestand (pin enabled terwijl zijn BUS_DIR nog op de
    # default RX staat -> "RX and TX cannot be combined in same nibble").
    set full [concat [hsci_disable_unused $ip $keep] $props]
    if {[catch {set_property -dict $full $ip} err]} {
        hsci_fail "de wizard weigert deze configuratie voor '$name':\n            $err" \
                  "de wizard-melding hierboven noemt meestal de precieze regel\
 (nibble-indeling, strobe-positie, poortnaam-botsing)"
    }

    # Rate-terugkoppeling: als de wizard klemt, weten we dat het part het niet trekt.
    set got [get_property -quiet CONFIG.PLL0_DATA_SPEED $ip]
    set want [dict get [dict create {*}$props] CONFIG.PLL0_DATA_SPEED]
    if {$got ne "" && [expr {abs($got - $want)}] > 0.01} {
        hsci_fail "wizard klemde PLL0_DATA_SPEED van $want naar $got Mb/s" \
                  "dit part haalt de gevraagde rate niet; verlaag cfg(data_speed) naar $got"
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
        hsci_warn "geen .veo gevonden voor $ip -- poortnamen NIET geverifieerd"
        return 0
    }
    set miss [list]
    foreach p $wanted { if {[lsearch -exact $have $p] < 0} { lappend miss $p } }
    if {[llength $miss] == 0} {
        puts "  ok $ip : alle [llength $wanted] voorspelde poorten bestaan"
        return 1
    }
    puts "  !! $ip : [llength $miss] voorspelde poort(en) bestaan NIET:"
    foreach p $miss { puts "       $p" }
    puts "     wizard biedt: [join $have {, }]"
    return 0
}

#=============================================================================
