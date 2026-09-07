###############################################################################
##  hsci_demo_check.tcl
##
##  The proof of the pudding: synthesize the generated top level
##  out-of-context. That catches everything a port check on names cannot see
##  -- wrong widths, a forgotten signal, an IP with different ports after all.
##
##      vivado -mode batch -source hsci_demo_check.tcl -tclargs <part> <gen_dir>
###############################################################################

set part_name [lindex $argv 0]
set gen_dir   [file normalize [lindex $argv 1]]

puts "\n===== SYNTHESIS CHECK ==========================================="
puts "  part : $part_name"
puts "  dir  : $gen_dir"

create_project -in_memory -part $part_name
source [file join $gen_dir hsci_demo_srcs.tcl]

# Each IP first out-of-context into its own DCP, only then the top level.
# That's the normal Vivado flow and here also the only one that works: set
# GENERATE_SYNTH_CHECKPOINT to false to synthesize all IP HDL in one go and
# Vivado 2025.1 crashes with EXCEPTION_ACCESS_VIOLATION while processing the
# XDC of high_speed_selectio_wiz 3.6. See docs/vivado-findings.md.
set_property GENERATE_SYNTH_CHECKPOINT true [get_files *.xci]
set_property top hsci_demo_top [current_fileset]

foreach ip [get_ips] {
    puts "  synth_ip $ip"
    if {[catch {synth_ip [get_ips $ip]} e]} {
        puts "\n**** IP '$ip' DOES NOT SYNTHESIZE ****\n$e\n"
        error "hsci_demo_check: synth_ip failed on $ip"
    }
}

if {[catch {synth_design -top hsci_demo_top -mode out_of_context} err]} {
    puts "\n**** THE TOP LEVEL DOES NOT SYNTHESIZE ****\n"
    puts $err
    puts ""
    error "hsci_demo_check: synth_design failed"
}

puts "\nok  hsci_demo_top synthesizes out-of-context"
puts [format "    cells: %d   nets: %d" \
    [llength [get_cells -quiet -hierarchical]] [llength [get_nets -quiet -hierarchical]]]

set prims [list]
foreach t {TX_BITSLICE RX_BITSLICE RXTX_BITSLICE BITSLICE_CONTROL RIU_OR \
           PLLE4_ADV MMCME4_ADV BUFG BUFGCE IBUFDS OBUFDS BSCANE2} {
    set n [llength [get_cells -quiet -hierarchical -filter "REF_NAME == $t"]]
    if {$n} { lappend prims "$t=$n" }
}
puts "    primitives: [join $prims {  }]"

puts "\n    clocks synthesis sees:"
foreach c [get_clocks -quiet] {
    puts [format "      %-24s %s ns" $c [get_property -quiet PERIOD $c]]
}

# Expected: "Clock 'sys_clk' completely overrides clock 'H20'". During its OOC
# synthesis the MMCM gets its own in_context XDC that defines the incoming
# clock with the same period but without a name; our hsci_demo_pins.xdc
# overrides it with a proper name. In a real project flow the top run doesn't
# read that in_context XDC and the message goes away.
set crit [get_msg_config -severity {CRITICAL WARNING} -count]
puts "\n    critical warnings: $crit"

puts "\n===== DONE ======================================================\n"
