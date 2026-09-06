###############################################################################
##  hsci_demo_check.tcl
##
##  De proef op de som: synthetiseer het gegenereerde toplevel out-of-context.
##  Dat pakt alles wat een poortcheck op namen niet ziet -- verkeerde breedtes,
##  een vergeten signaal, een IP dat toch andere poorten heeft.
##
##      vivado -mode batch -source hsci_demo_check.tcl -tclargs <part> <gen_dir>
###############################################################################

set part_name [lindex $argv 0]
set gen_dir   [file normalize [lindex $argv 1]]

puts "\n===== SYNTHESECHECK ============================================="
puts "  part : $part_name"
puts "  dir  : $gen_dir"

create_project -in_memory -part $part_name
source [file join $gen_dir hsci_demo_srcs.tcl]

# Elk IP eerst out-of-context naar zijn eigen DCP, daarna pas het toplevel.
# Dat is de normale Vivado-flow en hier ook de enige die werkt: zet je
# GENERATE_SYNTH_CHECKPOINT op false om alle IP-HDL in een keer mee te
# synthetiseren, dan crasht Vivado 2025.1 met EXCEPTION_ACCESS_VIOLATION bij
# het verwerken van de XDC van high_speed_selectio_wiz 3.6. Zie
# docs/vivado-bevindingen.md.
set_property GENERATE_SYNTH_CHECKPOINT true [get_files *.xci]
set_property top hsci_demo_top [current_fileset]

foreach ip [get_ips] {
    puts "  synth_ip $ip"
    if {[catch {synth_ip [get_ips $ip]} e]} {
        puts "\n**** IP '$ip' SYNTHETISEERT NIET ****\n$e\n"
        error "hsci_demo_check: synth_ip faalde op $ip"
    }
}

if {[catch {synth_design -top hsci_demo_top -mode out_of_context} err]} {
    puts "\n**** HET TOPLEVEL SYNTHETISEERT NIET ****\n"
    puts $err
    puts ""
    error "hsci_demo_check: synth_design faalde"
}

puts "\nok  hsci_demo_top synthetiseert out-of-context"
puts [format "    cellen: %d   nets: %d" \
    [llength [get_cells -quiet -hierarchical]] [llength [get_nets -quiet -hierarchical]]]

set prims [list]
foreach t {TX_BITSLICE RX_BITSLICE RXTX_BITSLICE BITSLICE_CONTROL RIU_OR \
           PLLE4_ADV MMCME4_ADV BUFG BUFGCE IBUFDS OBUFDS BSCANE2} {
    set n [llength [get_cells -quiet -hierarchical -filter "REF_NAME == $t"]]
    if {$n} { lappend prims "$t=$n" }
}
puts "    primitieven: [join $prims {  }]"

puts "\n    klokken die synthese ziet:"
foreach c [get_clocks -quiet] {
    puts [format "      %-24s %s ns" $c [get_property -quiet PERIOD $c]]
}

# Verwacht: "Clock 'sys_clk' completely overrides clock 'H20'". De MMCM krijgt
# bij zijn OOC-synthese een eigen in_context XDC die de inkomende klok met
# dezelfde periode maar zonder naam definieert; onze hsci_demo_pins.xdc
# overschrijft die met een nette naam. In een echt projectflow leest de
# top-run die in_context-XDC niet en is de melding weg.
set crit [get_msg_config -severity {CRITICAL WARNING} -count]
puts "\n    critical warnings: $crit"

puts "\n===== KLAAR =====================================================\n"
