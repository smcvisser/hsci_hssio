###############################################################################
##  hsci_pin_index.tcl
##
##  Het minimale geval: part + pin -> PKGPIN_BYTEGROUP_INDEX en
##  PKGPIN_NIBBLE_INDEX. Vivado geeft die twee zelf, dus er valt niets af te
##  leiden.
##
##      PKGPIN_BYTEGROUP_INDEX   0..12   positie in de byte group  (de N uit PIN_FUNC)
##      PKGPIN_NIBBLE_INDEX      0..6    positie in de nibble
##
##  De properties opvragen kost niets (~10 us per pin). De kosten zitten in
##  het eenmalig laden van de device database met link_design: ~25 s op een
##  xczu17eg. Daarom onthoudt deze proc welk part geladen is en doet hij dat
##  hooguit een keer per Vivado-sessie.
##
##      source scripts/hsci_pin_index.tcl
##      hsci_pin_index xczu17eg-ffvd1760-1-e AP18     ;# -> bytegroup 6 nibble 0
##
##  Wil je er meer bij (bitslice, BITSLICE_CONTROL-site, byte group nummer,
##  QBC/DBC): scripts/hsci_nibble.tcl.
###############################################################################

proc hsci_pin_index {part pin} {
    global hsci_pin_index_part

    # Device een keer laden. get_package_pins geeft NIETS terug voordat
    # link_design de device database heeft ingelezen.
    if {![info exists hsci_pin_index_part] || $hsci_pin_index_part ne $part} {
        if {[llength [current_project -quiet]] == 0} {
            create_project -in_memory -part $part
        }
        if {[llength [get_parts -quiet $part]] != 1} {
            error "part '$part' is niet bekend in deze Vivado-installatie"
        }
        link_design -part $part -name hsci_pin_index
        set hsci_pin_index_part $part
    }

    set pp [get_package_pins -quiet $pin]
    if {[llength $pp] != 1} {
        error "package pin '$pin' bestaat niet op $part"
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
