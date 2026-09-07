###############################################################################
##  hsci_demo_impl.tcl
##
##  Runs synthesis and implementation on the project hsci_demo_project.tcl
##  wrote. Batch, so it also works without the GUI.
##
##      vivado -mode batch -source hsci_demo_impl.tcl -tclargs <xpr> [jobs]
##
##  Stops at route_design; no bitstream. The point is whether the design links,
##  places and routes, and what timing it closes at.
###############################################################################

set xpr  [file normalize [lindex $argv 0]]
set jobs [expr {[llength $argv] > 1 ? [lindex $argv 1] : 4}]

if {![file exists $xpr]} {
    error "hsci_demo_impl: $xpr does not exist -- run build_demo.py --project first"
}

puts "\n===== IMPLEMENTATION ============================================"
puts "  project : $xpr"
puts "  jobs    : $jobs"

open_project $xpr

# hsci_demo_project.tcl switched these off; if that silently stopped working
# we want to know here and not from an access violation twenty minutes later.
puts "\n  constraint files link_design will read:"
foreach f [get_files -of_objects [get_filesets constrs_1]] {
    puts [format "    %-40s enabled=%s" [file tail $f] [get_property is_enabled $f]]
}
foreach ip [get_ips] {
    foreach f [get_files -quiet -of_objects [get_ips $ip] {*.xdc}] {
        puts [format "    %-40s enabled=%s" [file tail $f] [get_property is_enabled $f]]
    }
}

foreach run {impl_1 synth_1} {
    if {[get_property PROGRESS [get_runs $run]] ne "0%"} { reset_run $run }
}

puts "\n----- synth_1 ---------------------------------------------------"
launch_runs synth_1 -jobs $jobs
wait_on_run synth_1
if {[get_property PROGRESS [get_runs synth_1]] ne "100%"} {
    puts "\n**** SYNTHESIS FAILED ****"
    puts "     log: [get_property DIRECTORY [get_runs synth_1]]/runme.log"
    error "hsci_demo_impl: synth_1 did not finish"
}
puts "ok  synth_1 [get_property STATUS [get_runs synth_1]]"

puts "\n----- impl_1 ----------------------------------------------------"
launch_runs impl_1 -jobs $jobs
wait_on_run impl_1
if {[get_property PROGRESS [get_runs impl_1]] ne "100%"} {
    puts "\n**** IMPLEMENTATION FAILED ****"
    puts "     status: [get_property STATUS [get_runs impl_1]]"
    puts "     log: [get_property DIRECTORY [get_runs impl_1]]/runme.log"
    error "hsci_demo_impl: impl_1 did not finish"
}
puts "ok  impl_1 [get_property STATUS [get_runs impl_1]]"

open_run impl_1
puts "\n  timing:"
# STATS.WPWS is not a run property -- the pulse width number Vivado keeps per
# run is the total, TPWS.
set stats {
    "setup   WNS"      WNS
    "setup   TNS"      TNS
    "hold    WHS"      WHS
    "hold    THS"      THS
    "pulse width TPWS" TPWS
}
foreach {label prop} $stats {
    puts [format "    %-18s %s ns" $label [get_property STATS.$prop [get_runs impl_1]]]
}
puts "\n  cells: [llength [get_cells -quiet -hierarchical]]"

puts "\n===== DONE ======================================================\n"
