# ---------------------------------------------------------------------------
# ip_droute.tcl - COPY of OpenLane's scripts/openroad/droute.tcl (OpenLane
# 1.0.2) for gemm_ip, run by gemm_detailed_routing in ip_route_signoff.tcl.
# Differences, nothing else changed:
#   - -or_k $GEMM_DRT_OR_K [0.05] next to -or_seed (the help text says -or_k_,
#     the parser in TritonRoute.tcl reads -or_k). In this OpenROAD
#     (41a51ea, drt/src/dr/FlexDR_maze.cpp, mazeIterInit_sortRerouteNets) the
#     seed only drives nets x OR_K random swaps of the reroute order; with
#     OR_K = 0 (the default) no swap is made and every seed routes the same
#     (ip_v3r: seeds 42, 7 and 23 gave byte-identical DEF and DRC report);
#   - the seed and or_k in use are printed at the top of the log.
# ---------------------------------------------------------------------------
# Copyright 2020-2022 Efabless Corporation
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#      http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
set or_seed [expr {[info exists ::env(DRT_OR_SEED)] ? $::env(DRT_OR_SEED) : 42}]
set or_k    [expr {[info exists ::env(GEMM_DRT_OR_K)] ? $::env(GEMM_DRT_OR_K) : 0.05}]
puts "gemm_drt: detailed_route -or_seed $or_seed -or_k $or_k\
      (first maze iteration of each worker: nets x $or_k random swaps of the reroute order)"

source $::env(SCRIPTS_DIR)/openroad/common/io.tcl
read

set_thread_count $::env(ROUTING_CORES)

set min_layer $::env(RT_MIN_LAYER)
if { [info exists ::env(DRT_MIN_LAYER)] } {
    set min_layer $::env(DRT_MIN_LAYER)
}

set max_layer $::env(RT_MAX_LAYER)
if { [info exists ::env(DRT_MAX_LAYER)] } {
    set max_layer $::env(DRT_MAX_LAYER)
}

read_guides $::env(CURRENT_GUIDE)

detailed_route\
    -bottom_routing_layer $min_layer\
    -top_routing_layer $max_layer\
    -output_maze $::env(_tmp_drt_file_prefix)_maze.log\
    -output_drc $::env(_tmp_drt_rpt_prefix).drc\
    -droute_end_iter $::env(DRT_OPT_ITERS)\
    -or_seed $or_seed\
    -or_k $or_k\
    -verbose 1

write
