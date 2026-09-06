###############################################################################
##  hsci_check_wrapper.tcl
##
##  Elaboreert de gegenereerde hsci_phy_2bank.sv tegen de twee gegenereerde
##  wizard-IPs. De poortcheck in hsci_hssio_gen.tcl vergelijkt alleen namen met
##  de .veo; dit is de echte proef: bestaat elke poort, klopt elke breedte, en
##  slikt de synthese de wrapper.
##
##  Draai dit in dezelfde directory als hsci_hssio_gen.tcl (daar staan de
##  gegenereerde .xci's en hsci_phy_2bank.sv):
##
##      vivado -mode batch -source hsci_check_wrapper.tcl -tclargs <part> [dir]
###############################################################################

set part_name [expr {[llength $argv] > 0 ? [lindex $argv 0] : "xczu7ev-ffvf1517-2-e"}]
set work_dir  [expr {[llength $argv] > 1 ? [lindex $argv 1] : [pwd]}]

set wrapper [file join $work_dir hsci_phy_2bank.sv]
if {![file exists $wrapper]} {
    puts "  hsci_phy_2bank.sv niet gevonden in $work_dir -- draai eerst hsci_hssio_gen.tcl"
    return
}

set xcis [lsort [glob -nocomplain -directory $work_dir -join * sources_1 ip * *.xci]]
if {[llength $xcis] == 0} {
    set xcis [lsort [glob -nocomplain -directory $work_dir -join .srcs sources_1 ip * *.xci]]
}
if {[llength $xcis] < 2} {
    puts "  minder dan twee .xci gevonden onder $work_dir -- draai eerst hsci_hssio_gen.tcl"
    return
}

puts "\n===== ELABORATIE-CHECK =========================================="
puts "  part    : $part_name"
puts "  wrapper : $wrapper"
foreach x $xcis { puts "  ip      : $x" }

create_project -in_memory -part $part_name
foreach x $xcis { read_ip $x }

# read_ip zet alleen de .xci in het project; zonder gesynthetiseerd IP faalt de
# top-synthese met "module 'hsci_hssio_tx' not found". Elk IP eerst naar zijn
# eigen DCP dus.
#
# Niet in de verleiding komen om in plaats daarvan GENERATE_SYNTH_CHECKPOINT op
# false te zetten en alles in een keer te synthetiseren: Vivado 2025.1 crasht
# dan met EXCEPTION_ACCESS_VIOLATION bij het verwerken van de XDC van
# high_speed_selectio_wiz 3.6. Zie docs/vivado-bevindingen.md.
set_property GENERATE_SYNTH_CHECKPOINT true [get_files *.xci]
foreach ip [get_ips] {
    puts "  synth_ip $ip"
    if {[catch {synth_ip [get_ips $ip]} e]} {
        puts "\n**** IP '$ip' SYNTHETISEERT NIET ****\n$e\n"
        error "hsci_check_wrapper: synth_ip faalde op $ip"
    }
}

add_files -norecurse $wrapper
set_property top hsci_phy_2bank [current_fileset]

# Out-of-context: geen top-level IO-constraints nodig, wel echte elaboratie
# en synthese van de bitslices en de XPLL.
if {[catch {synth_design -top hsci_phy_2bank -mode out_of_context} err]} {
    puts "\n**** WRAPPER ELABOREERT NIET ****\n"
    puts $err
    puts ""
    error "hsci_check_wrapper: synth_design faalde"
}

puts "\nok  hsci_phy_2bank synthetiseert out-of-context"
puts [format "    cellen: %d   nets: %d" \
    [llength [get_cells -quiet -hierarchical]] [llength [get_nets -quiet -hierarchical]]]

set prims [list]
foreach t {TX_BITSLICE RX_BITSLICE RXTX_BITSLICE BITSLICE_CONTROL PLLE3_ADV PLLE4_ADV} {
    set n [llength [get_cells -quiet -hierarchical -filter "REF_NAME == $t"]]
    if {$n} { lappend prims "$t=$n" }
}
puts "    primitieven: [join $prims {  }]"
puts "\n===== KLAAR =====================================================\n"
