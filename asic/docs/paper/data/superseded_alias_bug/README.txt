Superseded results (kept for traceability, do not cite).
The 400-cycle window power (vcd_*), energy_50MHz.csv, macro_power_64.txt and the first IR-drop
run used vcd2act_ip.py, which kept only the last name of each VCD id. iverilog gives one id to
all names of a net (a top-level net and the row / AXI port it connects to), so the drivers of
the nets on the row / AXI boundary got no toggles (density 0, duty 0); OpenSTA then derived
their activity itself. Replaced by the whole-job runs (job_power.sh, vcd2act_phases.py with
alias handling): data/power/job_*, energy_job_50MHz.csv, power_by_phase_50MHz.csv, irdrop_v2*.
The first IR run also used PSM's default checkerboard of bumps, not the IP pins.
