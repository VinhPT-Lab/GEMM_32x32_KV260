# Trích log các bước PD của run ip_v3r

Ba file dưới đây trích nguyên văn từ log và report của run OpenLane `gemm_ip/runs/ip_v3r` (IP `gemm_ip`, top `GEMM_top`). Flow không chạy lại, chỉ đọc log. Đường dẫn tuyệt đối trên máy đã thay bằng `~` hoặc đường dẫn tương đối. Tạo lại bằng `bash extract_pd.sh <thư mục ra>`.

`ip_v3r` resume từ `ip_v3` ở bước route (`resume: ip_v3 -> ip_v3r (mode route)` trong `openlane.log`). Vì vậy log bước 1–15 trong thư mục run là log kế thừa từ `ip_v3`, còn bước 16 (sửa hold) chạy trong `ip_v3r`. STA ở bước 12 và 14 dùng SDC của `ip_v3`, chu kỳ 10 ns. Bước 16 dùng SDC dựng lại, chu kỳ 20 ns.

| Bước | File | Số chính (nguyên văn từ log) |
|---|---|---|
| 01 Nhập thiết kế | `01_nhap_thiet_ke.txt` | Linter: 0 `%Error`, 98 `%Warning`; Yosys `Number of cells: 42349` (32 ProcessingElementRow, 80 SRAM, 1 GemmAxiShell); `CLOCK_PERIOD "20"` |
| 04 Tối ưu bố trí | `04_toi_uu_bo_tri.txt` | Global placement `Finished with Overflow: 0.149492`, `TargetDensity: 0.55`; repair_design `Inserted 18357 buffers in 12337 nets` (10615 slew, 2175 cap, 284 fanout); sau resizer `Design area 40293824 u^2 53% utilization`; detailed placement `max displacement 32.2 u` |
| 06 Tối ưu sau CTS | `06_toi_uu_sau_cts.txt` | CTS `Created 4257 clock buffers` cho 22302 sink, skew 0.77; resizer `Inserted 46949 hold buffers`; sửa hold `hold wns -0.315` → `0.514`, `setup wns 3.482` (Typical, 20 ns) |
