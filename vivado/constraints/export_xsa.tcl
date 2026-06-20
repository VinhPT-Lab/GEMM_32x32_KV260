# export_xsa.tcl
# Generate bitstream and export XSA for GEMM_BD_wrapper.
# Run inside Vivado with the project opened, or source this script after adjusting paths.
#
# Output default:
#   <project_root>/GEMM_BD_wrapper.xsa

set script_dir [file dirname [file normalize [info script]]]
set repo_root  [file normalize [file join $script_dir "../.."]]

# If this script is used inside the original Vivado project, adjust this path if needed.
set xsa_out {E:/Everything_with_VIVADO/MM_final/GEMM_BD_wrapper.xsa}

# Optional: if no project is open, set your project path here.
set proj_path {E:/Everything_with_VIVADO/MM_final/MM_final.xpr}

if {[current_project -quiet] eq ""} {
    if {[file exists $proj_path]} {
        open_project $proj_path
    } else {
        error "No project is open and proj_path does not exist. Edit proj_path in export_xsa.tcl."
    }
} else {
    puts "Current project: [current_project]"
}

# Make sure BD is validated and saved.
if {[llength [get_files -quiet *GEMM_BD.bd]] > 0} {
    open_bd_design [get_files *GEMM_BD.bd]
    validate_bd_design
    save_bd_design
}

# Generate wrapper if needed.
set bd_files [get_files -quiet *GEMM_BD.bd]
if {[llength $bd_files] > 0} {
    set bd_file [lindex $bd_files 0]
    make_wrapper -files $bd_file -top -force
    set wrapper_files [glob -nocomplain [file join [get_property DIRECTORY [current_project]] "*.gen/sources_1/bd/GEMM_BD/hdl/GEMM_BD_wrapper.v"]]
    if {[llength $wrapper_files] > 0} {
        add_files -quiet -norecurse [lindex $wrapper_files 0]
    }
}

update_compile_order -fileset sources_1

# Run implementation and bitstream only if bitstream is not already generated.
launch_runs impl_1 -to_step write_bitstream -jobs 4
wait_on_run impl_1

set impl_status [get_property STATUS [get_runs impl_1]]
puts "impl_1 status: $impl_status"

# Export hardware platform including bitstream.
write_hw_platform -fixed -include_bit -force -file $xsa_out

puts "Exported XSA:"
puts "  $xsa_out"
