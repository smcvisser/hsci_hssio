###############################################################################
##  hsci_pin_index.tcl
##
##  The minimal case: part + pin -> PKGPIN_BYTEGROUP_INDEX and
##  PKGPIN_NIBBLE_INDEX. Vivado provides these two itself, so there is
##  nothing to derive.
##
##      PKGPIN_BYTEGROUP_INDEX   0..12   position in the byte group  (the N from PIN_FUNC)
##      PKGPIN_NIBBLE_INDEX      0..6    position in the nibble
##
##  Querying the properties costs nothing (~10 us per pin). The cost is in
##  the one-time load of the device database with link_design: ~25 s on an
##  xczu17eg. That's why this proc remembers which part is loaded and does
##  that at most once per Vivado session.
##
##      source scripts/hsci_pin_index.tcl
##      hsci_pin_index xczu17eg-ffvd1760-1-e AP18     ;# -> bytegroup 6 nibble 0
##
##  Want more (bitslice, BITSLICE_CONTROL site, byte group number,
##  QBC/DBC): scripts/hsci_nibble.tcl.
###############################################################################

proc hsci_pin_index {part pin} {
    global hsci_pin_index_part

    # Load the device once. get_package_pins returns NOTHING before
    # link_design has read in the device database.
    if {![info exists hsci_pin_index_part] || $hsci_pin_index_part ne $part} {
        if {[llength [current_project -quiet]] == 0} {
            create_project -in_memory -part $part
        }
        if {[llength [get_parts -quiet $part]] != 1} {
            error "part '$part' is not known in this Vivado installation"
        }
        link_design -part $part -name hsci_pin_index
        set hsci_pin_index_part $part
    }

    set pp [get_package_pins -quiet $pin]
    if {[llength $pp] != 1} {
        error "package pin '$pin' does not exist on $part"
    }
    return [dict create \
        bytegroup [get_property -quiet PKGPIN_BYTEGROUP_INDEX $pp] \
        nibble    [get_property -quiet PKGPIN_NIBBLE_INDEX    $pp]]
}

# CLI:  vivado -mode batch -source scripts/hsci_pin_index.tcl \
#              -tclargs xczu17eg-ffvd1760-1-e AP18 BB21 AM16
if {![info exists hsci_pin_index_library] && [info exists argv] && [llength $argv] > 1} {
    set p [lindex $argv 0]
    foreach pin [lrange $argv 1 end] {
        set d [hsci_pin_index $p $pin]
        puts [format "  %-6s bytegroup %-3s nibble %s" \
            $pin [dict get $d bytegroup] [dict get $d nibble]]
    }
}