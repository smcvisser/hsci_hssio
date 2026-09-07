###############################################################################
##  hsci_check_wrapper.tcl
##
##  Elaborates the generated hsci_phy_2bank.sv against the two generated
##  wizard IPs. The port check in hsci_hssio_gen.tcl only compares names to
##  the .veo; this is the real test: does every port exist, is every width
##  right, and does synthesis swallow the wrapper.
##
##  Run it in the same directory as hsci_hssio_gen.tcl (where the generated
##  .xci's and hsci_phy_2bank.sv live):
##
##      vivado -mode batch -source hsci_check_wrapper.tcl -tclargs <part> [dir]
###############################################################################

set part_name [expr {[llength $argv] > 0 ? [lindex $argv 0] : "xczu7ev-ffvf1517-2-e"}]
set work_dir  [expr {[llength $argv] > 1 ? [lindex $argv 1] : [pwd]}]

set wrapper [file join $work_dir hsci_phy_2bank.sv]
if {![file exists $wrapper]} {
    puts "  hsci_phy_2bank.sv not found in $work_dir -- run hsci_hssio_gen.tcl first"
    return
}

set xcis [lsort [glob -nocomplain -directory $work_dir -join * sources_1 ip * *.xci]]
if {[llength $xcis] == 0} {
    set xcis [lsort [glob -nocomplain -directory $work_dir -join .srcs sources_1 ip * *.xci]]
}
if {[llength $xcis] < 2} {
    puts "  fewer than two .xci found under $work_dir -- run hsci_hssio_gen.tcl first"
    return
}

puts "\n===== ELABORATION CHECK ========================================="
puts "  part    : $part_name"
puts "  wrapper : $wrapper"
foreach x $xcis { puts "  ip      : $x" }

create_project -in_memory -part $part_name
foreach x $xcis { read_ip $x }

# read_ip only puts the .xci into the project; without synthesized IP the
# top synthesis fails with "module 'hsci_hssio_tx' not found". So each IP
# first gets its own DCP.
#
# Don't be tempted to set GENERATE_SYNTH_CHECKPOINT to false instead and
# synthesize everything in one go: Vivado 2025.1 then crashes with
# EXCEPTION_ACCESS_VIOLATION while processing the XDC of
# high_speed_selectio_wiz 3.6. See docs/vivado-findings.md.
set_property GENERATE_SYNTH_CHECKPOINT true [get_files *.xci]
foreach ip [get_ips] {
    puts "  synth_ip $ip"
    if {[catch {synth_ip [get_ips $ip]} e]} {
        puts "\n**** IP '$ip' DOES NOT SYNTHESIZE ****\n$e\n"
        error "hsci_check_wrapper: synth_ip failed on $ip"
    }
}

add_files -norecurse $wrapper
set_property top hsci_phy_2bank [current_fileset]

# Out-of-context: no top-level IO constraints needed, but real elaboration
# and synthesis of the bitslices and the XPLL.
if {[catch {synth_design -top hsci_phy_2bank -mode out_of_context} err]} {
    puts "\n**** WRAPPER DOES NOT ELABORATE ****\n"
    puts $err
    puts ""
    error "hsci_check_wrapper: synth_design failed"
}

puts "\nok  hsci_phy_2bank synthesizes out-of-context"
puts [format "    cells: %d   nets: %d" \
    [llength [get_cells -quiet -hierarchical]] [llength [get_nets -quiet -hierarchical]]]

set prims [list]
foreach t {TX_BITSLICE RX_BITSLICE RXTX_BITSLICE BITSLICE_CONTROL PLLE3_ADV PLLE4_ADV} {
    set n [llength [get_cells -quiet -hierarchical -filter "REF_NAME == $t"]]
    if {$n} { lappend prims "$t=$n" }
}
puts "    primitives: [join $prims {  }]"
puts "\n===== DONE ======================================================\n"