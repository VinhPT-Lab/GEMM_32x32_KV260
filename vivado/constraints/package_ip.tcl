# package_ip.tcl
# Package GEMM_top as a reusable Vivado IP.
# Run after create_project.tcl or inside an opened Vivado project.
#
# Expected repo layout:
#   rtl/*.v
#   axi_ip/*.v
#
# Output:
#   ip_repo/GEMM_top_1_0

set script_dir [file dirname [file normalize [info script]]]
set repo_root  [file normalize [file join $script_dir "../.."]]
set ip_root    [file normalize [file join $repo_root "ip_repo/GEMM_top_1_0"]]

set vendor     "user.org"
set library    "user"
set name       "GEMM_top"
set version    "1.0"
set top_module "GEMM_top"

puts "Packaging IP to: $ip_root"

file delete -force $ip_root
file mkdir $ip_root

# Make sure source files are in the current project.
set rtl_dir [file join $repo_root "rtl"]
set axi_dir [file join $repo_root "axi_ip"]

if {[file exists $rtl_dir]} {
    set rtl_files [glob -nocomplain [file join $rtl_dir "*.v"]]
    if {[llength $rtl_files] > 0} {
        add_files -quiet -fileset sources_1 $rtl_files
    }
}

if {[file exists $axi_dir]} {
    set axi_files [glob -nocomplain [file join $axi_dir "*.v"]]
    if {[llength $axi_files] > 0} {
        add_files -quiet -fileset sources_1 $axi_files
    }
}

set_property top $top_module [current_fileset]
update_compile_order -fileset sources_1

# Package current project as IP.
ipx::package_project -root_dir $ip_root -vendor $vendor -library $library -taxonomy /UserIP -import_files -force

set core [ipx::current_core]
set_property name $name $core
set_property display_name "GEMM 32x32 INT8 Accelerator" $core
set_property description "GEMM 32x32 INT8 accelerator with AXI-Lite control, AXI Stream feature/weight inputs, and AXI Stream result output." $core
set_property version $version $core

# Try to infer bus interfaces automatically.
ipx::infer_bus_interfaces xilinx.com:signal:clock_rtl:1.0 $core
ipx::infer_bus_interfaces xilinx.com:signal:reset_rtl:1.0 $core

# Check and save IP.
ipx::check_integrity $core
ipx::save_core $core

# Add IP repo path to current project.
set_property ip_repo_paths [list [file join $repo_root "ip_repo"]] [current_project]
update_ip_catalog

puts "IP packaged successfully."
puts "IP repo path: [file join $repo_root ip_repo]"
