# Step 3: read the ip_v3r DEF, write it back unchanged, antenna check. No repair.
source [file join [file dirname [file normalize [info script]]] common.tcl]
set R $::env(ROUND)
read_def $P/in/GEMM_top.$R.def
puts "PROBE read_def $R: [el]"
write_def $P/s3/GEMM_top.$R.rt.def
puts "PROBE write_def $R: [el]"
ant_count s3/$R
