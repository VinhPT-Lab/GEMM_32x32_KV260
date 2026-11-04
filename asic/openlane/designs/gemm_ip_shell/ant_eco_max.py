#!/usr/bin/env python3
"""
ant_eco_max.py - gemm_core/ant_eco.py with a larger --max-total.

run_flow.sh (ip-shell) installs this file as DESIGN_DIR/ant_eco.py of
gemm_ip_shell and gemm_core/ant_eco.py next to it as ant_eco_core.py, so the
call in gemm_core/route_signoff.tcl (which passes no --max-total) runs the
core's script unchanged with --max-total $GEMM_ANT_ECO_MAX_TOTAL added. The
seed list of ant_seed.py can exceed the default of 3000 (ip_shell3: 3631).
"""
import os
import runpy
import sys

here = os.path.dirname(os.path.abspath(__file__))
if not any(a == "--max-total" or a.startswith("--max-total=") for a in sys.argv[1:]):
    sys.argv[1:1] = ["--max-total", os.environ.get("GEMM_ANT_ECO_MAX_TOTAL", "3000")]
sys.argv[0] = os.path.join(here, "ant_eco_core.py")
runpy.run_path(sys.argv[0], run_name="__main__")
