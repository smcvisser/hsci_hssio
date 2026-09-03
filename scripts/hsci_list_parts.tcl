###############################################################################
##  hsci_list_parts.tcl
##
##  Valideert het opgegeven part en laat zien welke speed grades er voor
##  hetzelfde device+package bestaan -- dus of een snellere variant in dezelfde
##  footprint uberhaupt bestelbaar is.
##
##      vivado -mode batch -source hsci_list_parts.tcl
###############################################################################

set part_name "xczu17eg-ffvd1760-1-e"

array set MAX_RATE_HP_NATIVE {
    -1 1250  -1L 1250  -1LI 1250  -1M 1250  -1I 1250
    -2 1600  -2L 1600  -2I  1600  -2LI 1600
    -3 1600
}

puts "\n===== OPGEGEVEN PART ============================================"
set p [get_parts -quiet $part_name]
if {[llength $p] != 1} {
    puts "  '$part_name' is NIET bekend in deze Vivado-installatie."
    puts "  Mogelijke oorzaken: typefout in het package, of de device support"
    puts "  voor dit device is niet geinstalleerd."
    set dev ""
    regexp {^([a-z0-9]+)-} $part_name -> dev
    if {$dev ne ""} {
        puts "\n  Wel bekend voor device '$dev':"
        foreach q [lsort [get_parts -quiet -filter "DEVICE == $dev"]] {
            puts "    $q"
        }
    }
    return
}

puts "  part         : $part_name"
puts "  device       : [get_property -quiet DEVICE  $p]"
puts "  package      : [get_property -quiet PACKAGE $p]"
puts "  architectuur : [get_property -quiet ARCHITECTURE $p]"
puts "  speed grade  : [get_property -quiet SPEED $p]"

set dev [get_property -quiet DEVICE  $p]
set pkg [get_property -quiet PACKAGE $p]

puts "\n===== SPEED GRADES IN DEZELFDE FOOTPRINT ($dev / $pkg) =========="
puts [format "  %-30s %-8s %s" "part" "speed" "max LVDS native (HP, RX 1:8)"]
puts "  [string repeat - 72]"
foreach q [lsort [get_parts -quiet -filter "DEVICE == $dev && PACKAGE == $pkg"]] {
    set sg [get_property -quiet SPEED $q]
    set r "?  (niet in tabel)"
    if {[info exists MAX_RATE_HP_NATIVE($sg)]} {
        set r "$MAX_RATE_HP_NATIVE($sg) Mb/s"
        if {$MAX_RATE_HP_NATIVE($sg) >= 1600} { append r "   <-- haalt HSCI op 1600" }
    }
    set mark [expr {$q eq $part_name ? "*" : " "}]
    puts [format " %s%-30s %-8s %s" $mark $q $sg $r]
}
puts "\n  (* = het part dat in de scripts staat)"
puts "  Tabelwaarden overgeschreven uit DS925 \"LVDS Native Mode Performance\";"
puts "  controleer ze zelf voor je een bestelbeslissing neemt.\n"
