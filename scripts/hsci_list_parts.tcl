###############################################################################
##  hsci_list_parts.tcl
##
##  Validates the given part and shows which speed grades exist for the same
##  device+package -- i.e. whether a faster variant is orderable in the same
##  footprint at all.
##
##      vivado -mode batch -source hsci_list_parts.tcl
###############################################################################

set part_name "xczu17eg-ffvd1760-1-e"

array set MAX_RATE_HP_NATIVE {
    -1 1250  -1L 1250  -1LI 1250  -1M 1250  -1I 1250
    -2 1600  -2L 1600  -2I  1600  -2LI 1600
    -3 1600
}

puts "\n===== GIVEN PART ================================================"
set p [get_parts -quiet $part_name]
if {[llength $p] != 1} {
    puts "  '$part_name' is NOT known in this Vivado installation."
    puts "  Possible causes: a typo in the package, or the device support"
    puts "  for this device is not installed."
    set dev ""
    regexp {^([a-z0-9]+)-} $part_name -> dev
    if {$dev ne ""} {
        puts "\n  Known for device '$dev':"
        foreach q [lsort [get_parts -quiet -filter "DEVICE == $dev"]] {
            puts "    $q"
        }
    }
    return
}

puts "  part         : $part_name"
puts "  device       : [get_property -quiet DEVICE  $p]"
puts "  package      : [get_property -quiet PACKAGE $p]"
puts "  architecture : [get_property -quiet ARCHITECTURE $p]"
puts "  speed grade  : [get_property -quiet SPEED $p]"

set dev [get_property -quiet DEVICE  $p]
set pkg [get_property -quiet PACKAGE $p]

puts "\n===== SPEED GRADES IN THE SAME FOOTPRINT ($dev / $pkg) =========="
puts [format "  %-30s %-8s %s" "part" "speed" "max LVDS native (HP, RX 1:8)"]
puts "  [string repeat - 72]"
foreach q [lsort [get_parts -quiet -filter "DEVICE == $dev && PACKAGE == $pkg"]] {
    set sg [get_property -quiet SPEED $q]
    set r "?  (not in table)"
    if {[info exists MAX_RATE_HP_NATIVE($sg)]} {
        set r "$MAX_RATE_HP_NATIVE($sg) Mb/s"
        if {$MAX_RATE_HP_NATIVE($sg) >= 1600} { append r "   <-- reaches HSCI at 1600" }
    }
    set mark [expr {$q eq $part_name ? "*" : " "}]
    puts [format " %s%-30s %-8s %s" $mark $q $sg $r]
}
puts "\n  (* = the part the scripts use)"
puts "  Table values copied from DS925 \"LVDS Native Mode Performance\";"
puts "  check them yourself before making an ordering decision.\n"