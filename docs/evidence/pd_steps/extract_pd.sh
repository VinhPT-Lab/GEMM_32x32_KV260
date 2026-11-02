#!/usr/bin/env bash
# Trích log 3 bước PD của run ip_v3r, chỉ đọc log, ghi ra thư mục $1
set -euo pipefail
R=~/OpenLane/designs/gemm_ip/runs/ip_v3r
OUT=$1
mkdir -p "$OUT"
cd "$R"
san() { sed -e "s#$HOME#~#g" -e 's#/openlane/designs/gemm_ip/runs/ip_v3r/#<run>/#g' -e 's#/openlane/designs/gemm_ip/runs/ip_v3/#<ip_v3>/#g' -e 's#/openlane/designs/#designs/#g'; }
noise='read_liberty|Using 1e|STA-0053|license|^OpenROAD|Writing |^Setting global'

{
echo "Run: OpenLane gemm_ip/runs/ip_v3r (IP gemm_ip, top GEMM_top)"
echo "Log: logs/synthesis/linter.log, logs/synthesis/1-synthesis.log, reports/synthesis/1-synthesis.AREA_0.stat.rpt, config.tcl"
echo "Lệnh: grep/sed/awk trên các file trên (bash extract_pd.sh <thư mục ra>, script nằm cạnh file này), đường dẫn tuyệt đối trong máy thay bằng ~, <run> = runs/ip_v3r, <ip_v3> = runs/ip_v3"
echo
echo "Ghi chú: ip_v3r resume từ ip_v3 ở bước route, các log bước 1-15 trong ip_v3r/logs được kế thừa từ ip_v3 (openlane.log):"
grep -E 'resume: ip_v3 ->|post-CTS SDC at' openlane.log
echo
echo "== Linter (logs/synthesis/linter.log) =="
echo "grep -c '%Error' linter.log: $(grep -c '%Error' logs/synthesis/linter.log || true)"
echo "grep -c '%Warning' linter.log: $(grep -c '%Warning' logs/synthesis/linter.log)"
echo "Phân loại warning (grep -o '%Warning-[A-Z]*' | sort | uniq -c):"
grep -o '%Warning-[A-Z]*' logs/synthesis/linter.log | sort | uniq -c
echo
echo "== Clock period (config.tcl) =="
grep -E 'env\(CLOCK_PERIOD\)|env\(CLOCK_PORT\)' config.tcl
echo
echo "== Liberty macro nạp vào Yosys (logs/synthesis/1-synthesis.log) =="
grep -E '^[0-9]+\. Executing Liberty frontend' logs/synthesis/1-synthesis.log
echo
echo "== LEF/LIB/GDS macro (config.tcl) =="
grep -E 'env\((EXTRA_LEFS|EXTRA_LIBS|EXTRA_GDS_FILES|CELLS_LEF|TECH_LEF|LIB_SYNTH_COMPLETE)\)' config.tcl
echo
echo "== Yosys stat (reports/synthesis/1-synthesis.AREA_0.stat.rpt), rút gọn: bỏ từng dòng cell chuẩn =="
grep -v -E '^\s+sky130_fd_sc_hd__' reports/synthesis/1-synthesis.AREA_0.stat.rpt | grep -v '^\s*$'
echo "Số loại cell chuẩn sky130_fd_sc_hd liệt kê: $(grep -c -E '^\s+sky130_fd_sc_hd__' reports/synthesis/1-synthesis.AREA_0.stat.rpt)"
echo "5 loại cell chuẩn nhiều nhất:"
grep -E '^\s+sky130_fd_sc_hd__' reports/synthesis/1-synthesis.AREA_0.stat.rpt | sort -k2 -n -r | head -5
} | san > "$OUT/01_nhap_thiet_ke.txt"

{
echo "Run: OpenLane gemm_ip/runs/ip_v3r (IP gemm_ip, top GEMM_top)"
echo "Log: logs/placement/8-global.log, logs/placement/10-resizer.log, logs/placement/11-detailed.log, reports/placement/12-dpl_sta.summary.rpt"
echo "Lệnh: grep/sed trên các file trên (bash extract_pd.sh <thư mục ra>, script nằm cạnh file này), đường dẫn tuyệt đối trong máy thay bằng ~, <ip_v3> = runs/ip_v3"
echo
echo "Ghi chú: log kế thừa từ ip_v3 (ip_v3r resume ở bước route). STA ở bước này dùng SDC của ip_v3; openlane.log ghi:"
grep -E 'post-CTS SDC at' openlane.log
echo
echo "== Global placement (logs/placement/8-global.log) =="
grep -E 'GPL-00(06|07|08|19|23)\]' logs/placement/8-global.log
grep -E 'InitialPlace\]  Iter: 1 ' logs/placement/8-global.log
grep -E 'NesterovSolve\] Iter' logs/placement/8-global.log | tail -1
grep -E 'NesterovSolve\] Finished' logs/placement/8-global.log
grep -E 'env\((PL_TARGET_DENSITY|FP_CORE_UTIL)\)' config.tcl | sed 's/^/config.tcl: /'
echo
echo "== Resizer sau placement, repair_design (logs/placement/10-resizer.log) =="
grep -E 'RSZ-|keep_rows_clear|displacement|HPWL|DPL-|Design area' logs/placement/10-resizer.log
echo
echo "== Detailed placement (logs/placement/11-detailed.log) =="
grep -E 'keep_rows_clear|displacement|HPWL|DPL-' logs/placement/11-detailed.log
echo "errors (logs/placement/11-detailed.errors): $(wc -l < logs/placement/11-detailed.errors) dòng"
echo
echo "== STA sau detailed placement (reports/placement/12-dpl_sta.summary.rpt) =="
grep -E '^(tns|wns|worst slack)|report_worst_slack' reports/placement/12-dpl_sta.summary.rpt
} | san > "$OUT/04_toi_uu_bo_tri.txt"

{
echo "Run: OpenLane gemm_ip/runs/ip_v3r (IP gemm_ip, top GEMM_top)"
echo "Log: logs/cts/13-cts.log, reports/cts/14-cts_sta.summary.rpt, reports/cts/14-cts_sta.skew.rpt, logs/cts/15-resizer.log, logs/cts/16-hold_fix.log"
echo "Lệnh: grep/sed trên các file trên (bash extract_pd.sh <thư mục ra>, script nằm cạnh file này), đường dẫn tuyệt đối trong máy thay bằng ~, <run> = runs/ip_v3r, <ip_v3> = runs/ip_v3"
echo
echo "Ghi chú: bước 13-15 là log kế thừa từ ip_v3 (STA dùng SDC 10 ns của ip_v3). Bước 16 chạy trong ip_v3r với SDC dựng lại, chu kỳ 20 ns. openlane.log ghi:"
grep -E 'resume: ip_v3 ->|post-CTS SDC at' openlane.log
echo
echo "== CTS (logs/cts/13-cts.log) =="
grep -E 'CTS-00(07|10|49|18|12|13|17)\]|CTS-0(098|099|100|101|102)\]' logs/cts/13-cts.log
sed -n '/^cts_report$/,/^cts_report_end$/p' logs/cts/13-cts.log
echo
echo "== Skew sau CTS (reports/cts/14-cts_sta.skew.rpt) =="
grep -v -E '^=+$|^\s*$' reports/cts/14-cts_sta.skew.rpt
echo
echo "== STA sau CTS, trước resizer (reports/cts/14-cts_sta.summary.rpt, corner Typical) =="
grep -E '^(tns|wns|worst slack)|report_worst_slack' reports/cts/14-cts_sta.summary.rpt
echo
echo "== Resizer sau CTS, repair_timing (logs/cts/15-resizer.log) =="
grep -v -E "$noise" logs/cts/15-resizer.log | grep -E 'RSZ-|keep_rows_clear|Design area'
echo "(log 15-resizer không in WNS/TNS; số trước là mục STA sau CTS ở trên, số sau là dòng 'before' của bước 16)"
echo
echo "== Sửa hold trước global route (logs/cts/16-hold_fix.log, ip_v3r) =="
grep -E 'Reading design constraints|gemm_hold_fix|RSZ-' logs/cts/16-hold_fix.log
} | san > "$OUT/06_toi_uu_sau_cts.txt"
