# create_project.tcl
# Recreate a Vivado project shell for GEMM 32x32 KV260.
# Run from Vivado Tcl Console:
#   source create_project.tcl
#
# NOTE:
# - This script creates a clean project and adds source files.
# - The Block Design itself should be recreated from ../bd/GEMM_BD.tcl.
# - Adjust REPO_ROOT if your folder layout is different.

set script_dir [file dirname [file normalize [info script]]]
set repo_root  [file normalize [file join $script_dir "../.."]]

set project_name "MM_final"
set project_dir  [file normalize [file join $repo_root "build/vivado_project"]]

set part_name  "xck26-sfvc784-2LV-c"
set board_part "xilinx.com:kv260_som:part0:1.4"

puts "Repo root    : $repo_root"
puts "Project dir  : $project_dir"
puts "Project name : $project_name"

file mkdir $project_dir

create_project -force $project_name $project_dir -part $part_name
set_property board_part $board_part [current_project]
set_property target_language Verilog [current_project]

# ------------------------------------------------------------
# Add RTL sources
# ------------------------------------------------------------
set rtl_dir [file join $repo_root "rtl"]
set axi_dir [file join $repo_root "axi_ip"]
set tb_dir  [file join $repo_root "tb"]

if {[file exists $rtl_dir]} {
    set rtl_files [glob -nocomplain [file join $rtl_dir "*.v"]]
    if {[llength $rtl_files] > 0} {
        add_files -fileset sources_1 $rtl_files
    }
}

if {[file exists $axi_dir]} {
    set axi_files [glob -nocomplain [file join $axi_dir "*.v"]]
    if {[llength $axi_files] > 0} {
        add_files -fileset sources_1 $axi_files
    }
}

if {[file exists $tb_dir]} {
    set tb_files [concat \
        [glob -nocomplain [file join $tb_dir "*.sv"]] \
        [glob -nocomplain [file join $tb_dir "*.v"]] \
    ]
    if {[llength $tb_files] > 0} {
        add_files -fileset sim_1 $tb_files
    }
}

update_compile_order -fileset sources_1
update_compile_order -fileset sim_1

puts "Project created."
puts "Next step:"
puts "  source ../bd/GEMM_BD.tcl"
