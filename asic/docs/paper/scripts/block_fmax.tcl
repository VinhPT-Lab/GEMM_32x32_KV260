# Setup-limited fmax of one hardened block run alone: worst setup slack of register-to-
# register paths (I/O paths depend on assumed I/O delays and are left out), with the
# block's signoff SPEF (RC nom) and propagated clock. fmax = 1 / (T - slack).
# env: FINAL (results/final of the run), DESIGN, LIBCORNER (tt | ss | ff)
array set LIBC {tt tt_025C_1v80 ff ff_n40C_1v95 ss ss_100C_1v60 ss14 ss_100C_1v40}
set lib $::env(PDK_ROOT)/sky130A/libs.ref
read_liberty $lib/sky130_fd_sc_hd/lib/sky130_fd_sc_hd__$LIBC($::env(LIBCORNER)).lib
read_verilog $::env(FINAL)/verilog/gl/$::env(DESIGN).nl.v
link_design $::env(DESIGN)
read_sdc $::env(FINAL)/sdc/$::env(DESIGN).sdc
set_propagated_clock [all_clocks]
read_spef $::env(FINAL)/spef/$::env(DESIGN).spef
set T [get_property [lindex [all_clocks] 0] period]
set r2r [find_timing_paths -from [all_registers -clock_pins] -to [all_registers -data_pins] -path_delay max -group_count 1]
set s_r2r [get_property [lindex $r2r 0] slack]
puts [format "FMAX %s %s period %.3f ns: reg2reg slack %.3f ns -> fmax %.1f MHz" \
    $::env(DESIGN) $::env(LIBCORNER) $T $s_r2r [expr {1000.0 / ($T - $s_r2r)}]]
report_checks -from [all_registers -clock_pins] -to [all_registers -data_pins] -path_delay max -format full_clock_expanded
