###############################################################################
##  hsci_demo_project.tcl
##
##  Maakt een echt Vivado-project op schijf van de gegenereerde bestanden, zodat
##  je het in de GUI kunt openen. De rest van de demo draait op
##  `create_project -in_memory`, en dat schrijft per definitie geen .xpr.
##
##      vivado -mode batch -source hsci_demo_project.tcl -tclargs <part> <gen_dir>
##
##  Daarna:
##
##      vivado <gen_dir>/vivado_project/hsci_demo.xpr
##
##  De IP's worden met read_ip op hun plek gelaten (in generated/.srcs), niet
##  gekopieerd: een kopie zou stilletjes uit de pas gaan lopen met wat
##  build_demo.py genereert. Het project is dus een venster op de gegenereerde
##  bestanden, geen tweede waarheid.
###############################################################################

set part_name [lindex $argv 0]
set gen_dir   [file normalize [lindex $argv 1]]
set proj_dir  [file join $gen_dir vivado_project]
set proj_name "hsci_demo"

if {![file exists [file join $gen_dir hsci_demo_srcs.tcl]]} {
    puts "  hsci_demo_srcs.tcl niet gevonden in $gen_dir -- draai eerst build_demo.py"
    return
}

puts "\n===== PROJECT AANMAKEN =========================================="
puts "  part : $part_name"
puts "  map  : $proj_dir"

create_project $proj_name $proj_dir -part $part_name -force
source [file join $gen_dir hsci_demo_srcs.tcl]

set_property top hsci_demo_top [current_fileset]
update_compile_order -fileset sources_1

puts "\n  top        : [get_property top [current_fileset]]"
puts "  bronnen    : [llength [get_files -of_objects [get_filesets sources_1]]] bestanden"
puts "  IP         : [join [get_ips] {, }]"
puts "  constraints: [llength [get_files -of_objects [get_filesets constrs_1]]]"

set xpr [file join $proj_dir ${proj_name}.xpr]
close_project

puts "\nok  project geschreven"
puts "    open het met:  vivado $xpr"
puts "\n===== KLAAR =====================================================\n"
