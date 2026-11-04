#!/usr/bin/env python3
"""
gen_core_files.py - floorplan of the hardened GEMM core (GemmAccelerator) for
OpenLane v1: 32 row macros (row_v1, unchanged) + 80 sky130 OpenRAM macros
(sky130_sram_2kbyte_1rw1r_32x512_8) + standard cells.

usage:
  gen_core_files.py --pe-area 6603.8336 [--layout v3]
options: --util 0.55 --w-depth 1024 --f-depth 512 --o-depth 512
         --name-style escaped|plain  --out designs

--layout v1 (default; core_v1 and core_v1r were built with it, plus the
  gap options): region A 5x10 SRAMs west of the rows, region B 8x4 SRAMs
  along the bottom.

--layout v3: every SRAM sits next to the logic it talks to, so the long
  shift registers (FeatureSkew 7.9k flops, OutputDeskew 10.4k flops) and
  the buffer data buses never have to cross a macro. core_v1r's congestion
  map showed exactly those crossings: the OutputDeskew chains of lanes 0-15
  running diagonally through region B to SRAMs 2-4 mm west of their array
  column, and the FeatureSkew chains of the lower rows running from
  feeder SRAMs that sat up to 1 mm above their rows.

     W pins       | A: BufferFeeder, lane l = |  strip  |  32 row macros         |
   (cfg, clk)     |  [FW b0][FW b1][FF]  beside|(Feature| (group l = rows 4l..4l+3,
                  |  row group l, 620 um pitch | Skew)  |  same y as feeder lane l)
   ---------------+----------------------------+---------+------------------------
     W pins       | A: InputBuffer, lane l =   |         | band: OutputDeskew     |
   (weight and    |  [IW b0][IW b1][IF]        |         | B: 4 x 8 SRAM under    |
    feature data) |  one row per lane          |         |  the rows, lane j at   |
                  |                            |         |  column j//8 (= under  |
                  |                            |         |  array columns 8c..8c+7)
     S pins (result stream) under region B only

  The compute stream of lane l (FF_l or FW_l through Buffer_feeder's mux)
  goes east into the strip at the height of its rows and down to the weight
  inputs at the bottom of row 31; InputBuffer lane l feeds the feeder lane l
  straight above it.

Kept from the array stage: row pitch/channels, PDN halo 2 um, tap halo 1 um
vertically, met5 pitch = row period / 3 phased to the channels, east strip
thinner than the tap halo.

writes designs/gemm_core/{sizes.tcl, macro.cfg, pin_order.cfg} and prints a
summary; exits non-zero if any geometry rule fails.
"""
import argparse
import math
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from gen_openlane_files import SITE_H, M2, snap_up, snap_down, row_size  # noqa: E402

SRAM = "sky130_sram_2kbyte_1rw1r_32x512_8"
SW, SH = 683.1, 416.54          # SRAM macro (LEF SIZE)
SRAM_W, SRAM_D = 32, 512        # word width / depth of one macro
CORE_M = 4 * SITE_H             # OpenLane core margin top/bottom
CORE_X = 12 * M2                # OpenLane core margin left/right
PDN_HALO, TAP_HALO, TAP_HALO_Y, M4_SPACE = 2.0, 10.0, 1.0, 0.3
HW, HS = 1.6, 4.0               # met5 strap width, VDD-VSS gap


def macros_of(prefix, width, depth):
    """instance names sram_1r1w creates: g_bank[b].g_lane[l].u_macro"""
    nl = math.ceil(width / SRAM_W)
    nb = math.ceil(depth / SRAM_D)
    return [(f"{prefix}.g_bank[{b}].g_lane[{l}].u_macro", b, l) for l in range(nl) for b in range(nb)]


def esc(name, bit):
    return f"{name}\\[{bit}\\]"


def snap_site(y):
    """nearest y on the site-row grid"""
    return round(CORE_M + round((y - CORE_M) / SITE_H) * SITE_H, 2)


def ctl_pins():
    return ["i_clk", "i_rst_n"] + [esc("i_cfg_shift", b) for b in range(10)] + \
        [esc("i_cfg_row_count", b) for b in range(9)] + [esc("i_cfg_k_block_count", b) for b in range(5)] + \
        [esc("i_cfg_n_block_count", b) for b in range(5)]


def place_side(pins, lo, hi, length):
    """pin_order lines putting `pins` evenly between lo and hi on an edge of
    `length`: OpenLane's io_place spaces all slots of a side evenly, '$N' are
    N empty slots"""
    total = max(len(pins), round(len(pins) * length / max(hi - lo, 1.0)))
    before = min(total - len(pins), max(0, round(total * lo / length)))
    after = total - len(pins) - before
    out = ([f"${before}"] if before else []) + pins + ([f"${after}"] if after else [])
    return out


# ---------------------------------------------------------------------------
def layout_v1(a, n, dw, row_w, row_h, gap, period, feeder, inbuf, outbuf, ab):
    sgx = snap_up(a.a_gap_x if a.a_gap_x is not None else a.sram_gap_x, M2)      # region A
    s_pitch_y = snap_up(SH + a.sram_gap_y, SITE_H)       # keeps every SRAM on the site grid
    s_pitch_x = snap_up(SW + sgx, M2)
    b_gap_y = a.b_gap_y if a.b_gap_y is not None else a.sram_gap_y
    b_pitch_y = snap_up(SH + b_gap_y, SITE_H)
    region_a = feeder + inbuf
    A_COLS, B_COLS = 5, 8
    a_rows = math.ceil(len(region_a) / A_COLS)
    b_rows = math.ceil(len(outbuf) / B_COLS)

    west = snap_up(60.0, M2)                       # pin buffers + InputBuffer control
    xa0 = snap_up(CORE_X + west, M2)
    a_w = A_COLS * SW + (A_COLS - 1) * sgx
    strip = snap_up(a.strip if a.strip is not None else 200.0, M2)   # FeatureSkew
    x_rows = snap_up(xa0 + a_w + 20.0 + strip, M2)
    margin_e = CORE_X + snap_down(TAP_HALO / 2, M2)
    die_w = round(x_rows + row_w + margin_e, 2)

    south = snap_up(108.8, SITE_H)                 # result pins + quantizer/output regs
    yb0 = round(CORE_M + south, 2)
    b_h = (b_rows - 1) * b_pitch_y + SH
    band = snap_up(a.band if a.band is not None else 360.0, SITE_H)   # OutputDeskew
    y_low = snap_up(yb0 + b_h + b_gap_y + band, SITE_H)   # lowest row (row n-1)
    ys = [round(y_low + (n - 1 - i) * period, 2) for i in range(n)]   # row i bottom
    rows_top = ys[0] + row_h
    die_h = round(rows_top + gap + CORE_M, 2)       # top band = one channel (phased)
    a_h = (a_rows - 1) * s_pitch_y + SH
    ya_top = rows_top                               # A top-aligned with the rows
    ya0 = snap_down(ya_top - a_h, SITE_H)
    b_right = x_rows + row_w
    if a.b_gap_x in (None, ""):
        sgx_b = sgx if a.a_gap_x is None else snap_up(a.sram_gap_x, M2)
    elif a.b_gap_x == "spread":
        b_west = snap_up(CORE_X + 20.0, M2)
        sgx_b = snap_down((b_right - b_west - B_COLS * SW) / (B_COLS - 1), M2)
    else:
        sgx_b = snap_up(float(a.b_gap_x), M2)
    b_pitch_x = snap_up(SW + sgx_b, M2)
    xb0 = snap_down(b_right - ((B_COLS - 1) * b_pitch_x + SW), M2)

    place = []        # (name, x, y, orient, w, h)
    for i, y in enumerate(ys):
        place.append((f"{ab}.g_pe_row[{i}].u_row", x_rows, y, "N", row_w, row_h))
    if a_rows != 10 or len(region_a) != 48:
        print("region A slot map is written for 48 macros in 5x10 (W1024/F512); adapt it for other depths")
        return None
    ff, fw = feeder[:8], feeder[8:]
    inf, inw = inbuf[:8], inbuf[8:]
    slots = []
    slots += [(m, 4, r) for m, r in zip(ff, range(0, 8))]
    fw_slots = [(4, 8), (4, 9)] + [(3, r) for r in range(4, 10)] + [(2, r) for r in range(4, 10)] + [(1, 8), (1, 9)]
    slots += [(m, c, r) for m, (c, r) in zip(fw, fw_slots)]
    inf_slots = [(3, r) for r in range(0, 4)] + [(2, r) for r in range(0, 4)]
    slots += [(m, c, r) for m, (c, r) in zip(inf, inf_slots)]
    inw_slots = [(1, r) for r in range(0, 8)] + [(0, r) for r in range(2, 10)]
    slots += [(m, c, r) for m, (c, r) in zip(inw, inw_slots)]
    used = [(c, r) for _, c, r in slots]
    assert len(set(used)) == len(used) == 48, "region A slot clash"
    for (name, b, l), col, r in slots:
        x = round(xa0 + col * s_pitch_x, 2)
        y = round(ya0 + (a_rows - 1 - r) * s_pitch_y, 2)
        place.append((name, x, y, "N", SW, SH))
    for k, (name, b, l) in enumerate(outbuf):
        col, r = k // b_rows, k % b_rows
        x = round(xb0 + col * b_pitch_x, 2)
        y = round(yb0 + (b_rows - 1 - r) * b_pitch_y, 2)
        place.append((name, x, y, "N", SW, SH))

    extra_bad = []
    if ya0 < yb0 + b_h + b_gap_y - 1e-6:
        extra_bad.append("region A runs into region B")
    if xb0 < CORE_X:
        extra_bad.append("region B wider than the die")

    feat = [esc("i_feature_data", b) for b in range(n * dw)] + ["i_feature_valid", "i_feature_last", "o_feature_ready"]
    wgt = [esc("i_weight_data", b) for b in range(n * dw)] + ["i_weight_valid", "i_weight_last", "o_weight_ready"]
    res = [esc("o_result_data", b) for b in range(n * dw)] + ["o_result_valid", "o_result_last", "i_result_ready"]
    # clock + control in the middle of the west edge, streams either side
    pin_text = "#W\n" + "\n".join(wgt + ctl_pins() + feat) + "\n#S\n" + "\n".join(res) + "\n"

    summary = [
        f"macros    : {n} rows + {len(region_a)} SRAM in A ({A_COLS}x{a_rows}) + {len(outbuf)} SRAM in B "
        f"({B_COLS}x{b_rows}) = {len(place)}  (SRAM {(len(region_a) + len(outbuf)) * SW * SH / 1e6:.1f} mm2)",
        None,   # rows line (filled by main)
        f"region A  : x {xa0:.2f}..{xa0 + a_w:.2f}  y {ya0:.2f}..{ya0 + a_h:.2f}  "
        f"gaps x {s_pitch_x - SW:.2f} y {s_pitch_y - SH:.2f}",
        f"region B  : x {xb0:.2f}..{xb0 + (B_COLS - 1) * b_pitch_x + SW:.2f}  y {yb0:.2f}..{yb0 + b_h:.2f}  "
        f"gaps x {b_pitch_x - SW:.2f} y {b_pitch_y - SH:.2f}",
    ]
    return place, die_w, die_h, ys, x_rows, pin_text, summary, extra_bad


# ---------------------------------------------------------------------------
def layout_v3(a, n, dw, row_w, row_h, gap, period, feeder, inbuf, outbuf, ab):
    if n != 32 or len(feeder) != 24 or len(inbuf) != 24 or len(outbuf) != 32:
        print("layout v3 is written for a 32x32 array with W1024/F512/O512 (24 + 24 + 32 SRAMs)")
        return None
    lanes = 8
    ff = {l: m for m, b, l in feeder if "feature_tile" in m}
    fw = {(l, b): m for m, b, l in feeder if "weight_tile" in m}
    inf = {l: m for m, b, l in inbuf if "feature_mem" in m}
    inw = {(l, b): m for m, b, l in inbuf if "weight_mem" in m}
    assert len(ff) == len(inf) == lanes and len(fw) == len(inw) == 2 * lanes

    # ---- x: [west pins] A col0 col1 col2 [20] strip [rows / region B] [east]
    gx_a = snap_up(a.a_gap_x if a.a_gap_x is not None else 150.0, M2)
    pitch_ax = snap_up(SW + gx_a, M2)
    west = snap_up(60.0, M2)
    xa0 = snap_up(CORE_X + west, M2)
    a_w = 2 * pitch_ax + SW
    x_strip = snap_up(xa0 + a_w + 20.0, M2)
    strip = snap_up(a.strip if a.strip is not None else 320.0, M2)
    x_rows = snap_up(x_strip + strip, M2)
    margin_e = CORE_X + snap_down(TAP_HALO / 2, M2)
    die_w = round(x_rows + row_w + margin_e, 2)

    # ---- region B: 4 columns under the rows, 8 deep. --b-wide starts it under
    # the FeatureSkew strip (100 um after its west edge) for wider column gaps.
    B_COLS, B_ROWS = 4, 8
    xb0 = snap_up(x_strip + 100.0, M2) if a.b_wide else x_rows
    pitch_bx = snap_down(SW + (x_rows + row_w - xb0 - B_COLS * SW) / (B_COLS - 1), M2)
    gy_b = a.b_gap_y if a.b_gap_y is not None else 120.0
    pitch_by = snap_up(SH + gy_b, SITE_H)
    south = snap_up(108.8, SITE_H)                 # result pins + quantizer/output regs
    yb0 = round(CORE_M + south, 2)
    b_h = (B_ROWS - 1) * pitch_by + SH
    band = snap_up(a.band if a.band is not None else 400.0, SITE_H)   # OutputDeskew
    y_low = snap_up(yb0 + b_h + band, SITE_H)
    ys = [round(y_low + (n - 1 - i) * period, 2) for i in range(n)]
    rows_top = ys[0] + row_h
    die_h = round(rows_top + gap + CORE_M, 2)

    place = []
    for i, y in enumerate(ys):
        place.append((f"{ab}.g_pe_row[{i}].u_row", x_rows, y, "N", row_w, row_h))

    def ax(col):
        return round(xa0 + col * pitch_ax, 2)

    # ---- A upper half: feeder lane l beside rows 4l..4l+3 (centred on the group)
    up_y = {}
    for l in range(lanes):
        top = ys[4 * l] + row_h
        bot = ys[4 * l + 3]
        y = snap_site((top + bot) / 2 - SH / 2)
        up_y[l] = y
        place.append((fw[(l, 0)], ax(0), y, "N", SW, SH))
        place.append((fw[(l, 1)], ax(1), y, "N", SW, SH))
        place.append((ff[l], ax(2), y, "N", SW, SH))
    upper_bottom = min(up_y.values())

    # ---- A lower half: InputBuffer lane l, lane 0 at the top, down to the B bottom
    gy_mid = 150.0
    lower_top_y = upper_bottom - gy_mid - SH          # y of lane 0's SRAM row
    pitch_low = snap_down((lower_top_y - yb0) / (lanes - 1), SITE_H)
    low_y = {}
    for l in range(lanes):
        y = round(yb0 + (lanes - 1 - l) * pitch_low, 2)
        low_y[l] = y
        place.append((inw[(l, 0)], ax(0), y, "N", SW, SH))
        place.append((inw[(l, 1)], ax(1), y, "N", SW, SH))
        place.append((inf[l], ax(2), y, "N", SW, SH))

    # ---- region B: lane j under array columns 8c..8c+7, j = 8c + r, r = 0 at the top
    for k, (name, b, j) in enumerate(outbuf):
        c, r = j // 8, j % 8
        place.append((name, round(xb0 + c * pitch_bx, 2), round(yb0 + (B_ROWS - 1 - r) * pitch_by, 2), "N", SW, SH))

    extra_bad = []
    if pitch_low - SH < 100.0:
        extra_bad.append(f"InputBuffer rows too close ({pitch_low - SH:.1f} um gaps)")
    if xb0 + (B_COLS - 1) * pitch_bx + SW > x_rows + row_w + 1e-6:
        extra_bad.append("region B wider than the rows")

    # ---- pins. West, bottom -> top: data streams beside the InputBuffer half
    # (lane 7 lowest, like the SRAM rows), then stream control and cfg/clk.
    data = []
    for l in reversed(range(lanes)):
        data += [esc("i_weight_data", b) for b in reversed(range(32 * l, 32 * l + 32))]
        data += [esc("i_feature_data", b) for b in reversed(range(32 * l, 32 * l + 32))]
    data += ["i_weight_valid", "i_weight_last", "o_weight_ready",
             "i_feature_valid", "i_feature_last", "o_feature_ready"]
    west_pins = data + ctl_pins()
    lo, hi = yb0, upper_bottom + 300.0       # cfg/clk end up just above the data
    west_lines = place_side(west_pins, lo, hi, die_h)
    # South: result bytes in lane order under region B (lane j sits at x ~ column j)
    res = [esc("o_result_data", b) for b in range(n * dw)] + ["o_result_valid", "o_result_last", "i_result_ready"]
    south_lines = place_side(res, x_rows, x_rows + row_w, die_w)
    pin_text = "#W\n" + "\n".join(west_lines) + "\n#S\n" + "\n".join(south_lines) + "\n"

    summary = [
        f"macros    : {n} rows + 48 SRAM in A (3 columns: feeder lanes beside their rows, InputBuffer "
        f"lanes below) + 32 SRAM in B (4x8 under the rows) = {len(place)}",
        None,
        f"region A  : x {xa0:.2f}..{xa0 + a_w:.2f}, column gaps {pitch_ax - SW:.2f}; feeder rows pitch "
        f"{4 * period:.2f} (gaps {4 * period - SH:.2f}), InputBuffer rows y {yb0:.2f}..{lower_top_y + SH:.2f} "
        f"pitch {pitch_low:.2f} (gaps {pitch_low - SH:.2f})",
        f"region B  : x {xb0:.2f}..{xb0 + (B_COLS - 1) * pitch_bx + SW:.2f}  y {yb0:.2f}..{yb0 + b_h:.2f}  "
        f"gaps x {pitch_bx - SW:.2f} y {pitch_by - SH:.2f}; OutputDeskew band {band:.2f}; strip {strip:.2f}",
    ]
    return place, die_w, die_h, ys, x_rows, pin_text, summary, extra_bad


# ---------------------------------------------------------------------------
def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--n", type=int, default=32)
    ap.add_argument("--dw", type=int, default=8)
    ap.add_argument("--riw", type=int, default=5)
    ap.add_argument("--pe-area", type=float)
    ap.add_argument("--row-w", type=float)
    ap.add_argument("--row-h", type=float)
    ap.add_argument("--util", type=float, default=0.55)
    ap.add_argument("--gap", type=float, default=21.76, help="channel between rows (um)")
    ap.add_argument("--w-depth", type=int, default=1024)
    ap.add_argument("--f-depth", type=int, default=512)
    ap.add_argument("--o-depth", type=int, default=512)
    ap.add_argument("--layout", choices=["v1", "v3"], default="v1",
                    help="v1: region A 5x10 west + region B 8x4 south (core_v1/v1r); v3: SRAMs next to their logic")
    ap.add_argument("--sram-gap-x", type=float, default=40.0, help="v1: gap between SRAM columns")
    ap.add_argument("--sram-gap-y", type=float, default=59.84, help="v1: gap between SRAM rows (pins on top and bottom edges)")
    # The OpenRAM macro blocks met1-met4 over its whole area (only met5, which
    # is horizontal, crosses it), so every vertical wire in an SRAM region runs
    # in the column gaps.
    ap.add_argument("--a-gap-x", type=float, help="gap between region A columns (v1 default --sram-gap-x, v3 150)")
    ap.add_argument("--b-gap-x", help="v1: gap between region B columns: um, or 'spread' (default --sram-gap-x)")
    ap.add_argument("--b-gap-y", type=float, help="gap between region B rows (v1 default --sram-gap-y, v3 120)")
    ap.add_argument("--strip", type=float,
                    help="FeatureSkew strip between region A and the rows (v1 200, v3 320 um)")
    ap.add_argument("--band", type=float, help="OutputDeskew band under the rows (v1 360, v3 400 um)")
    ap.add_argument("--b-wide", action="store_true",
                    help="v3: region B starts under the FeatureSkew strip instead of under row 0's west edge")
    ap.add_argument("--name-style", choices=["escaped", "plain"], default="escaped")
    ap.add_argument("--out", default=os.path.join(os.path.dirname(os.path.abspath(__file__)), "designs"))
    a = ap.parse_args()
    if not ((a.row_w and a.row_h) or a.pe_area):
        ap.error("give --pe-area, or --row-w and --row-h")

    n, dw = a.n, a.dw
    row_w, row_h = row_size(n, a.pe_area, a.util, a.row_w, a.row_h)
    gap = snap_up(a.gap, SITE_H)
    period = row_h + gap

    ab = "u_buffer_feeder.u_compute_core.u_processing_element_array"
    feeder = macros_of("u_buffer_feeder.u_feature_tile_mem", n * dw, 1 << 9) + \
        macros_of("u_buffer_feeder.u_weight_tile_mem", n * dw, (1 << 5) * n)
    inbuf = macros_of("u_input_buffer.u_feature_mem", n * dw, a.f_depth) + \
        macros_of("u_input_buffer.u_weight_mem", n * dw, a.w_depth)
    outbuf = macros_of("u_output_buffer.u_accum_mem", n * 32, a.o_depth)

    fn = layout_v3 if a.layout == "v3" else layout_v1
    r = fn(a, n, dw, row_w, row_h, gap, period, feeder, inbuf, outbuf, ab)
    if r is None:
        return 1
    place, die_w, die_h, ys, x_rows, pin_text, summary, extra_bad = r

    # ---------------------------------------------------------- met5 straps
    hpitch = period / 3
    core_top = die_h - CORE_M
    vdd_c = ys[1] + row_h + gap / 2 - (HW + HS) / 2
    hoffset = (vdd_c - CORE_M) % hpitch

    def pairs():
        c = CORE_M + hoffset
        while c < core_top:
            yield (c - HW / 2, c + HW + HS + HW / 2)
            c += hpitch

    def n_pairs(lo, hi, slack):
        return sum(1 for p0, p1 in pairs() if p0 >= lo + slack and p1 <= hi - slack)

    # ---------------------------------------------------------- checks
    bad = list(extra_bad)
    keep = PDN_HALO + M4_SPACE
    for (nm, x, y, o, w, h) in place:
        if x < CORE_X - 1e-6 or y < CORE_M - 1e-6 or x + w > die_w - CORE_X + 1e-6 or y + h > die_h - CORE_M + 1e-6:
            bad.append(f"outside the core: {nm}")
        if abs((y - CORE_M) / SITE_H - round((y - CORE_M) / SITE_H)) > 1e-6:
            bad.append(f"off the site-row grid: {nm} y={y}")
    for i in range(len(place)):
        n1, x1, y1, _, w1, h1 = place[i]
        for j in range(i + 1, len(place)):
            n2, x2, y2, _, w2, h2 = place[j]
            if x1 < x2 + w2 - 1e-6 and x2 < x1 + w1 - 1e-6 and y1 < y2 + h2 - 1e-6 and y2 < y1 + h1 - 1e-6:
                bad.append(f"overlap: {n1} / {n2}")
    if not n_pairs(ys[0] + row_h + keep, core_top, 1.0):
        bad.append("band above row 0 has no met5 pair across its met4")
    for i in range(n - 1):
        if not n_pairs(ys[i + 1] + row_h + keep, ys[i] - keep, 1.0):
            bad.append(f"channel {i}/{i + 1}: no met5 pair")
    for (nm, x, y, o, w, h) in place:
        lo, hi = (y + CORE_M, y + h - CORE_M) if nm.endswith("u_row") else (y + 4.76, y + 411.78)
        if n_pairs(lo, hi, 0.5) < (1 if nm.endswith("u_row") else 2):
            bad.append(f"too few met5 pairs over the power pins of {nm}")
    if len(place) != n + len(feeder) + len(inbuf) + len(outbuf):
        bad.append(f"placed {len(place)} macros, expected {n + len(feeder) + len(inbuf) + len(outbuf)}")
    if bad:
        print("core floorplan check FAILED:\n  " + "\n  ".join(bad[:40]))
        return 1

    # ---------------------------------------------------------- write files
    d = os.path.join(a.out, "gemm_core")
    os.makedirs(d, exist_ok=True)

    def nm_out(s):
        return s.replace("[", "\\[").replace("]", "\\]") if a.name_style == "escaped" else s

    with open(os.path.join(d, "macro.cfg"), "w") as f:
        f.write("# instance  x  y  orientation   (generated by gen_core_files.py)\n")
        for (nm, x, y, o, w, h) in place:
            f.write(f"{nm_out(nm)} {x:.2f} {y:.2f} {o}\n")

    with open(os.path.join(d, "sizes.tcl"), "w") as f:
        f.write("# generated by gen_core_files.py - do not edit, rerun the script\n")
        f.write(f"set ::env(FP_SIZING) absolute\nset ::env(DIE_AREA) \"0 0 {die_w:.2f} {die_h:.2f}\"\n")
        f.write(f"# PDN: met5 pitch = row period {period:.2f} / 3, one VDD/VSS pair through every\n"
                "# row channel and the top band; SRAM gaps hold cell rows (rails tie the met4)\n")
        f.write(f"set ::env(FP_PDN_HORIZONTAL_HALO) {PDN_HALO}\nset ::env(FP_PDN_VERTICAL_HALO)   {PDN_HALO}\n"
                f"set ::env(FP_TAP_HORIZONTAL_HALO) {TAP_HALO}\nset ::env(FP_TAP_VERTICAL_HALO)   {TAP_HALO_Y}\n")
        f.write(f"set ::env(FP_PDN_HWIDTH)   {HW}\nset ::env(FP_PDN_HSPACING) {HS}\n"
                f"set ::env(FP_PDN_HPITCH)   {hpitch:.2f}\nset ::env(FP_PDN_HOFFSET)  {hoffset:.2f}\n")
        f.write(f"# expected hard macros (checked by run_flow.sh)\nset ::env(GEMM_CORE_MACROS) {len(place)}\n")
        srams = [(x, y, w, h) for (nm, x, y, o, w, h) in place if (w, h) == (SW, SH)]
        obs = ", ".join(f"met5 {x:.2f} {y:.2f} {x + w:.2f} {y + h:.2f}" for (x, y, w, h) in srams)
        f.write(f"# met5 over each of the {len(srams)} SRAM macros (routing obstruction, see config.tcl)\n"
                f"set ::env(GEMM_SRAM_MET5_OBS) \"{obs}\"\n")

    with open(os.path.join(d, "pin_order.cfg"), "w") as f:
        f.write(pin_text)

    summary[1] = (f"rows      : x={x_rows:.2f}, lowest y={ys[-1]:.2f}, period {period:.2f}; "
                  f"met5 pitch {hpitch:.2f} offset {hoffset:.2f}")
    print(f"core die  : {die_w:.2f} x {die_h:.2f} um = {die_w * die_h / 1e6:.1f} mm2  (layout {a.layout})")
    for s in summary:
        print(s)
    print(f"written under {d}  (floorplan checks OK)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
