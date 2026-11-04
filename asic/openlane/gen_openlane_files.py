#!/usr/bin/env python3
"""
gen_openlane_files.py - generate every geometry file the OpenLane v1 flow
needs, from ONE set of numbers, so the row macro and the array always agree.

usage:
  gen_openlane_files.py --pe-area 6560            # size the row from the PE run
  gen_openlane_files.py --row-w 3510 --row-h 122.4  # or give the row size directly
options: --n 32 --dw 8 --riw 5 --util 0.55 --gap 21.76 --left 200 --bottom 360
         --name-style escaped|plain  --out designs

writes:
  designs/gemm_row/sizes.tcl       DIE_AREA of the row macro
  designs/gemm_row/pin_order.cfg   psum/weight pins column by column, N and S
                                   with the SAME count and order -> OpenLane's
                                   io_place.py puts bit b at the same x on both
                                   edges, so stacked rows connect straight down
  designs/gemm_array/sizes.tcl     DIE_AREA of the array
  designs/gemm_array/pin_order.cfg features + control west, weights + results south
  designs/gemm_array/macro.cfg     the N row macros stacked, row 0 on top

--name-style: how the macro instance names are written in macro.cfg.
  escaped: g_pe_row\\[3\\].u_row   (what OpenROAD usually shows for generate names)
  plain  : g_pe_row[3].u_row
If floorplan stops with "Macros not found", switch style (see the doc).
"""
import argparse
import math
import os

SITE_H = 2.72   # sky130hd row height
M2 = 0.46       # met2 pitch (vertical pins, macro x origin)


def snap_up(v, g):
    return math.ceil(round(v / g, 6)) * g


def snap_down(v, g):
    return math.floor(round(v / g, 6)) * g


def row_size(n, pe_area=None, util=0.55, row_w=None, row_h=None):
    """Row macro die (um). Shared by the array and the core generators, so the
    hardened row_v1 always matches what they place."""
    if row_w and row_h:
        return snap_up(row_w, M2), snap_up(row_h, SITE_H)
    # each PE roughly square at the target utilisation; >= 45 um per column
    # so 29 pins per column fit comfortably on the met2 grid
    slot = max(45.0, math.sqrt(pe_area / util))
    core_w = snap_up(n * slot, M2)
    core_h = snap_up(n * pe_area / util / core_w, SITE_H)
    # OpenLane default core margins: 4 site rows top/bottom, 12 site widths left/right
    return snap_up(core_w + 2 * 12 * M2, M2), snap_up(core_h + 2 * 4 * SITE_H, SITE_H)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--n", type=int, default=32)
    ap.add_argument("--dw", type=int, default=8)
    ap.add_argument("--riw", type=int, default=5)
    ap.add_argument("--pe-area", type=float, help="PE cell area in um^2 (from the gemm_pe run)")
    ap.add_argument("--row-w", type=float)
    ap.add_argument("--row-h", type=float)
    ap.add_argument("--util", type=float, default=0.55)
    ap.add_argument("--gap", type=float, default=21.76, help="channel between rows (um), rounded up to whole site rows")
    ap.add_argument("--left", type=float, default=200.0, help="west strip for FeatureSkew (um)")
    ap.add_argument("--bottom", type=float, default=360.0, help="south strip for OutputDeskew + pins (um)")
    ap.add_argument("--name-style", choices=["escaped", "plain"], default="escaped")
    ap.add_argument("--out", default=os.path.join(os.path.dirname(os.path.abspath(__file__)), "designs"))
    a = ap.parse_args()

    n, dw, riw = a.n, a.dw, a.riw
    psw = 2 * dw + riw

    # ---------------------------------------------------------------- row size
    if not ((a.row_w and a.row_h) or a.pe_area):
        ap.error("give --pe-area, or --row-w and --row-h")
    row_w, row_h = row_size(n, a.pe_area, a.util, a.row_w, a.row_h)

    # --------------------------------------------------------------- array size
    # PDN rules (why array_v1 died with PSM-0069 "Check connectivity failed"):
    # pdngen cuts the parent's met4 straps only where a row macro has met4
    # obstructions (+ min spacing + FP_PDN halo); met5 is never cut, the row
    # stops at met4. So a short met4 piece is left in every channel between
    # rows and in the band above row 0, and each piece needs a met5 VDD/VSS pair
    # running across it, or it floats. Hence:
    #  - every vertical size is a whole number of site rows, rows repeat with
    #    period = row_h + gap, and the band above row 0 is one gap tall;
    #  - met5 pitch = period/3, offset chosen so one pair runs through the
    #    middle of every channel and of the top band, two pairs cross each row;
    #  - FP_PDN halo 2 um (was 10) so the met4 piece always spans the channel;
    #  - east strip thinner than the tap halo: no std-cell rows there that
    #    could miss a met4 strap.
    # Rows ARE kept inside the channels (tap halo 1 um vertically): the
    # resizer puts hold buffers on the row-to-row nets (weight shift chain is
    # flop-to-flop across macros). With no rows in the channels array_v1
    # parked them all in the west strip and every such net ran ~2x the die
    # width over the macros on met5 -> GRT-0119. In the channel they sit
    # right under the net.
    CORE_M = 4 * SITE_H                       # OpenLane core margin top/bottom
    CORE_X = 12 * M2                          # OpenLane core margin left/right
    PDN_HALO, TAP_HALO, TAP_HALO_Y, M4_SPACE = 2.0, 10.0, 1.0, 0.3
    HW, HS = 1.6, 4.0                         # met5 strap width, VDD-VSS gap
    gap = snap_up(a.gap, SITE_H)
    margin = CORE_M + gap                     # top band phased like a channel
    bottom = snap_up(a.bottom, SITE_H)
    period = row_h + gap
    x = snap_down(a.left, M2)
    margin_e = CORE_X + snap_down(TAP_HALO / 2, M2)
    arr_w = round(x + row_w + margin_e, 2)
    arr_h = round(bottom + n * row_h + (n - 1) * gap + margin, 2)
    ys = [round(arr_h - margin - (i + 1) * row_h - i * gap, 2) for i in range(n)]   # row i bottom

    # met5 VDD strap centres = CORE_M + HOFFSET + k*HPITCH, VSS = VDD + HW + HS
    # (centre-relative-to-core checked against the array_v1 PDN log)
    hpitch = period / 3
    core_top = arr_h - CORE_M
    vdd_c = ys[1] + row_h + gap / 2 - (HW + HS) / 2       # middle of channel row1/row0
    hoffset = (vdd_c - CORE_M) % hpitch

    def pairs():
        c = CORE_M + hoffset
        while c < core_top:
            yield (c - HW / 2, c + HW + HS + HW / 2)       # VDD bottom .. VSS top
            c += hpitch

    def has_pair(lo, hi, slack):
        return any(p0 >= lo + slack and p1 <= hi - slack for p0, p1 in pairs())

    keep = PDN_HALO + M4_SPACE    # met4 always survives this far from a row edge
    problems = []
    if not has_pair(ys[0] + row_h + keep, core_top, 1.0):
        problems.append("band above row 0: no met5 pair across its met4")
    for i in range(n - 1):
        if not has_pair(ys[i + 1] + row_h + keep, ys[i] - keep, 1.0):
            problems.append(f"channel {i}/{i + 1}: no met5 pair across its met4")
    for i, y in enumerate(ys):
        if not has_pair(y + CORE_M, y + row_h - CORE_M, 0.5):
            problems.append(f"row {i}: no met5 pair over its power pins")
    if problems:
        raise SystemExit("PDN geometry check failed:\n  " + "\n  ".join(problems))

    row_dir = os.path.join(a.out, "gemm_row")
    arr_dir = os.path.join(a.out, "gemm_array")
    os.makedirs(row_dir, exist_ok=True)
    os.makedirs(arr_dir, exist_ok=True)

    with open(os.path.join(row_dir, "sizes.tcl"), "w") as f:
        f.write("# generated by gen_openlane_files.py - do not edit, rerun the script\n")
        f.write(f"set ::env(FP_SIZING) absolute\nset ::env(DIE_AREA) \"0 0 {row_w:.2f} {row_h:.2f}\"\n")

    with open(os.path.join(arr_dir, "sizes.tcl"), "w") as f:
        f.write("# generated by gen_openlane_files.py - do not edit, rerun the script\n")
        f.write(f"set ::env(FP_SIZING) absolute\nset ::env(DIE_AREA) \"0 0 {arr_w:.2f} {arr_h:.2f}\"\n")
        f.write(f"# PDN (see gen_openlane_files.py): met5 pitch = row period {period:.2f} / 3,\n"
                "# offset puts one VDD/VSS pair through every channel and the top band\n")
        f.write(f"set ::env(FP_PDN_HORIZONTAL_HALO) {PDN_HALO}\nset ::env(FP_PDN_VERTICAL_HALO)   {PDN_HALO}\n"
                f"set ::env(FP_TAP_HORIZONTAL_HALO) {TAP_HALO}\nset ::env(FP_TAP_VERTICAL_HALO)   {TAP_HALO_Y}\n")
        f.write(f"set ::env(FP_PDN_HWIDTH)   {HW}\nset ::env(FP_PDN_HSPACING) {HS}\n"
                f"set ::env(FP_PDN_HPITCH)   {hpitch:.2f}\nset ::env(FP_PDN_HOFFSET)  {hoffset:.2f}\n")

    # --------------------------------------------------------- row pin order
    def esc(name, bit):
        return f"{name}\\[{bit}\\]"

    north, south = [], []
    for j in range(n):
        for b in range(psw):
            north.append(esc("i_partial_sum_vector", j * psw + b))
            south.append(esc("o_partial_sum_vector", j * psw + b))
        for b in range(dw):
            north.append(esc("o_weight_shift_out", j * dw + b))
            south.append(esc("i_weight_shift_in", j * dw + b))
    west = ["i_clk", "i_rst_n", "i_weight_shift_en", "i_weight_load"] + \
           [esc("i_feature_value", b) for b in range(dw)]
    assert len(north) == len(south)
    with open(os.path.join(row_dir, "pin_order.cfg"), "w") as f:
        f.write("#N\n" + "\n".join(north) + "\n#S\n" + "\n".join(south) + "\n#W\n" + "\n".join(west) + "\n")

    # ------------------------------------------------------- array pin order
    # west listed row 0 first and reversed (#WR) -> row 0 features end up at the top
    feat = [esc("i_feature_vector", r * dw + b) for r in range(n) for b in range(dw)]
    ctrl = ["i_clk", "i_rst_n", "i_weight_shift_en", "i_weight_load"]
    bottom = []
    for j in range(n):
        bottom += [esc("i_weight_shift_in", j * dw + b) for b in range(dw)]
        bottom += [esc("o_partial_sum_vector", j * psw + b) for b in range(psw)]
    # clock/control pins in the MIDDLE of the west edge (between row n/2-1 and
    # n/2): at the bottom corner the clock ran ~2.5 mm on one weak net to the
    # CTS root (2.2 ns, 2.8 ns slew, antenna on the trunk in array_v1)
    half = (n // 2) * dw
    with open(os.path.join(arr_dir, "pin_order.cfg"), "w") as f:
        f.write("#WR\n" + "\n".join(feat[:half] + ctrl + feat[half:]) + "\n#S\n" + "\n".join(bottom) + "\n")

    # ------------------------------------------------------------ macro.cfg
    lines = ["# instance  x  y  orientation   (generated by gen_openlane_files.py)"]
    for i, y in enumerate(ys):
        name = f"g_pe_row\\[{i}\\].u_row" if a.name_style == "escaped" else f"g_pe_row[{i}].u_row"
        lines.append(f"{name} {x:.2f} {y:.2f} N")
    with open(os.path.join(arr_dir, "macro.cfg"), "w") as f:
        f.write("\n".join(lines) + "\n")

    lowest = ys[-1]
    print(f"row macro : {row_w:.2f} x {row_h:.2f} um   ({len(north)} pins on N and on S)")
    print(f"array     : {arr_w:.2f} x {arr_h:.2f} um   (lowest row at y={lowest:.2f}, "
          f"{lowest:.0f} um left below for OutputDeskew)")
    ch_rows = int(round((gap - 2 * snap_up(TAP_HALO_Y, SITE_H)) / SITE_H))
    print(f"channels  : {ch_rows} cell rows each (hold buffers go there)")
    print(f"channels  : {gap:.2f} um, row period {period:.2f}, met5 pitch {hpitch:.2f} offset {hoffset:.2f} (PDN check OK)")
    if a.pe_area:
        print(f"row util  : {n * a.pe_area / (row_w * row_h):.0%} of die")
    print(f"written under {a.out}/gemm_row and {a.out}/gemm_array")


if __name__ == "__main__":
    main()
