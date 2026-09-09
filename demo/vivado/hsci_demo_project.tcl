###############################################################################
##  hsci_demo_project.tcl
##
##  Creates a real Vivado project on disk from the generated files, so you can
##  open it in the GUI. The rest of the demo runs on `create_project -in_memory`,
##  which by definition never writes a .xpr.
##
##      vivado -mode batch -source hsci_demo_project.tcl -tclargs <part> <gen_dir>
##
##  Daarna:
##
##      vivado <gen_dir>/vivado_project/hsci_demo.xpr
##
##  The IPs are left in place with read_ip (in generated/.srcs), not copied: a
##  copy would silently drift out of sync with what build_demo.py generates.
##  The project is therefore a window onto the generated files, not a second
##  source of truth.
###############################################################################

set part_name [lindex $argv 0]
set gen_dir   [file normalize [lindex $argv 1]]
set proj_dir  [file join $gen_dir vivado_project]
set proj_name "hsci_demo"

if {![file exists [file join $gen_dir hsci_demo_srcs.tcl]]} {
    puts "  hsci_demo_srcs.tcl not found in $gen_dir -- run build_demo.py first"
    return
}

puts "\n===== CREATING PROJECT =========================================="
puts "  part : $part_name"
puts "  dir  : $proj_dir"

create_project $proj_name $proj_dir -part $part_name -force
source [file join $gen_dir hsci_demo_srcs.tcl]

set_property top hsci_demo_top [current_fileset]
update_compile_order -fileset sources_1

# The XDC of high_speed_selectio_wiz sets PACKAGE_PIN, IOSTANDARD and DATA_RATE
# on the same eight ports as hsci_demo_pins.xdc. Synthesis never sees it -- for
# an IP it only reads the *_in_context.xdc -- but link_design does, and Vivado
# 2025.1 dies there with EXCEPTION_ACCESS_VIOLATION. So we switch those two
# files off and let hsci_demo_pins.xdc own all I/O; what they constrained
# beyond the pins is repeated in there. See docs/vivado-findings.md.
#
# The *_ooc.xdc of the same IP stays enabled: that one drives the IP's own
# out-of-context synthesis and never reaches the top level.
foreach ip [get_ips] {
    if {![string match *high_speed_selectio_wiz* [get_property IPDEF $ip]]} {
        continue
    }
    set xdc [get_files -quiet -of_objects [get_ips $ip] "*/$ip.xdc"]
    if {[llength $xdc] != 1} {
        error "hsci_demo_project: expected one $ip.xdc, found [llength $xdc]: $xdc"
    }
    set_property is_enabled false $xdc
    puts "  disabled   : [file tail $xdc]  (I/O comes from hsci_demo_pins.xdc)"
}

puts "\n  top        : [get_property top [current_fileset]]"
puts "  sources    : [llength [get_files -of_objects [get_filesets sources_1]]] files"
puts "  IP         : [join [get_ips] {, }]"
puts "  constraints: [llength [get_files -of_objects [get_filesets constrs_1]]]"

set xpr [file join $proj_dir ${proj_name}.xpr]
close_project

puts "\nok  project written"
puts "    open it with:  vivado $xpr"
puts "\n===== DONE ======================================================\n"
