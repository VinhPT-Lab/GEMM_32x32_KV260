#!/usr/bin/env python3
"""
gen_ip_files.py - floorplan of the complete AXI accelerator IP (design gemm_ip,
top GEMM_top) and of the AXI macro it contains (design gemm_ip_shell,
GemmAxiShell lean + clock gating, hardened as a block).

The IP is the core_v11 floorplan moved by (DX, DY), with the AXI macro as a
tall, narrow block along the West edge of the die:

     die W pins | AXI macro (u_axi_shell) |  core_v11 floorplan, moved by (DX, DY):
   (AXI4-Lite, |  W pins: AXIS / AXI-Lite |  region A (InputBuffer / feeder SRAMs),
    3 x AXIS)  |  E pins: core side, each |  FeatureSkew strip, 32 rows,
               |  at the y where core_v11 |  region B (OutputBuffer SRAMs)
               |  had its West pin        |
               |  E bottom: result bus  <-|-- south band (DY taller than core_v11):
               |                          |   o_result_data from region B, westwards

  - core side of the macro (East edge): every pin at exactly the y (+ DY) of
    the core_v11 West pin it replaces (i_weight_data[b] -> o_weight_data[b],
    i_cfg_* -> o_cfg_*, i_rst_n -> o_core_rst_n), so the inside of the core,
    which routed clean in core_v11, sees its inputs where it always did;
  - the result bus (core_v11: South pins under region B) enters the macro at
    the bottom of its East edge, in the band under region A and B that DY
    makes taller; bit 0 lowest (lane order = x order under region B);
  - AXIS bit i on the West edge sits on the same track as its core-side bit
    on the East edge (the slices are bit-sliced: straight wire through the
    macro); TSTRB bits go in free tracks next to their byte;
  - every West pin of the macro has the die pin of the same name on the same
    track, straight across the gap between the die edge and the macro;
  - S_AXI_ACLK: macro pin at the top of the East edge, die pin just above the
    macro, so the clock reaches the core without crossing the macro.

Pin positions are computed exactly as OpenLane's io_place.py places a
pin_order.cfg (pins on every second met3 track, '$N' = N empty slots, slots
centred): with (tracks - 1) slots on a side, slot k is pin-track k.

DY is a multiple of the met5 pitch, so the met5 straps keep their offset;
the met4 offset moves with DX (FP_PDN_VOFFSET), so every strap sits where it
was relative to the macros.

usage: gen_ip_files.py --pe-area <um2> [core floorplan options, as core_v11]
                       [--check-def <core_v11 final def>] [--out designs]
       gen_ip_files.py --rtl <GemmAxiShell netlist> [--out designs]
writes designs/gemm_ip_shell/{sizes.tcl,pin_order.cfg},
       designs/gemm_ip/{sizes.tcl,macro.cfg,pin_order.cfg,floorplan.txt};
--rtl: designs/gemm_ip/{GEMM_top_ip.v,GemmAxiShell_bb.v}.
Exits non-zero if a geometry or alignment check fails.
"""
import argparse
import math
import os
import re
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from gen_openlane_files import SITE_H, M2, snap_up  # noqa: E402
from gen_axi_files import axil_pins  # noqa: E402

CORE_M = 4 * SITE_H          # OpenLane core margin top/bottom (as gen_core_files.py)
CORE_X = 12 * M2             # OpenLane core margin left/right
T_ORG, T_STEP = 0.34, 0.68   # met3 track grid (sky130 tracks.info)
P_STEP = 2 * T_STEP          # io_place: pins on every second met3 track
HW, HS = 1.6, 4.0            # met5 strap width, VDD-VSS gap (gen_core_files.py)
VPITCH, VOFFSET = 153.6, 16.32   # met4 straps of core_v11 (OpenLane defaults)
AXI_ADDR = 6
PREFIX = "u_gemm_accelerator."
SHELL_INST = "u_axi_shell"


def pin_tracks(height):
    """number of pin slots io_place.py has on a W/E edge of `height` um"""
    n = int(math.floor((round(height * 1000) - 340) / 680)) + 1
    return (n + 1) // 2


def track_y(k):
    return round(T_ORG + k * P_STEP, 2)


def io_slots(entries, n):
    """io_place.py equally_spaced_sequence: {pin: slot index}"""
    virt = sum(int(e[1:]) for e in entries if e.startswith("$"))
    act = sum(1 for e in entries if not e.startswith("$"))
    total = act + virt
    if total > n or (total == n and virt):
        raise SystemExit(f"io_slots: {total} slots on an edge with {n} pin tracks")
    tpp = n // total
    cur = (n - (tpp * (total - 1) + 1)) // 2
    out = {}
    for e in entries:
        if e.startswith("$"):
            cur += tpp * int(e[1:])
        else:
            out[e.replace("\\", "")] = cur
            cur += tpp
    return out


def exact_side(pos, n):
    """pin_order lines putting pin p on pin-track pos[p] (io_place with n tracks)"""
    items = sorted(pos.items(), key=lambda kv: kv[1])
    ks = [k for _, k in items]
    if len(set(ks)) != len(ks):
        dup = sorted({k for k in ks if ks.count(k) > 1})
        raise SystemExit(f"exact_side: two pins on track(s) {dup[:5]}")
    if ks[0] < 0 or ks[-1] > n - 2:
        raise SystemExit(f"exact_side: tracks {ks[0]}..{ks[-1]} outside 0..{n - 2}")
    lines, cur = [], 0
    for name, k in items:
        if k > cur:
            lines.append(f"${k - cur}")
        lines.append(re.sub(r"\[(\d+)\]", r"\\[\1\\]", name))
        cur = k + 1
    if n - 1 - cur > 0:
        lines.append(f"${n - 1 - cur}")
    got = io_slots(lines, n)
    assert got == {p: k for p, k in pos.items()}, "exact_side: io_place would put the pins elsewhere"
    return lines


def read_core(args, tmp):
    """core_v11 floorplan, regenerated by gen_core_files.py into tmp"""
    cmd = [sys.executable, os.path.join(HERE, "gen_core_files.py"), "--pe-area", str(args.pe_area),
           "--out", tmp] + args.core_args
    r = subprocess.run(cmd, capture_output=True, text=True)
    if r.returncode:
        raise SystemExit("gen_core_files.py failed:\n" + r.stdout + r.stderr)
    d = os.path.join(tmp, "gemm_core")
    sizes = open(os.path.join(d, "sizes.tcl")).read()
    env = dict(re.findall(r'set ::env\((\w+)\)\s+"?([^"\n]*)"?', sizes))
    die = [float(v) for v in env["DIE_AREA"].split()]
    macros = []
    for line in open(os.path.join(d, "macro.cfg")):
        if line.startswith("#") or not line.strip():
            continue
        n, x, y, o = line.split()
        macros.append((n.replace("\\", ""), float(x), float(y), o))
    sides, cur = {}, None
    for line in open(os.path.join(d, "pin_order.cfg")):
        t = line.strip()
        if t.startswith("#"):
            cur = t
            sides[cur] = []
        elif t:
            sides[cur].append(t)
    return r.stdout, env, die, macros, sides


def def_west_pins(path):
    """{pin: y} of the West pins in a DEF"""
    out, inp, cur = {}, False, None
    for line in open(path, errors="ignore"):
        if line.startswith("PINS"):
            inp = True
            continue
        if line.startswith("END PINS"):
            break
        if not inp:
            continue
        m = re.match(r"\s*- (\S+) \+ NET", line)
        if m:
            cur = m.group(1)
        m = re.search(r"PLACED \( (-?\d+) (-?\d+) \)", line)
        if m and cur and int(m.group(1)) < 5000:
            out[cur] = int(m.group(2)) / 1000.0
            cur = None
    return out


def bits(name, w):
    return [f"{name}[{b}]" for b in range(w)]


def lef_size(path, macro):
    s = open(path, errors="ignore").read()
    m = re.search(r"MACRO\s+" + macro + r"\b.*?SIZE\s+([\d.]+)\s+BY\s+([\d.]+)", s, re.S)
    return (float(m.group(1)), float(m.group(2))) if m else None


# ---------------------------------------------------------------------------
def floorplan(a):
    tmp = tempfile.mkdtemp(prefix="gen_ip_")
    core_txt, env, die, macros, sides = read_core(a, tmp)
    cw, ch = die[2], die[3]
    hpitch, hoff = float(env["FP_PDN_HPITCH"]), float(env["FP_PDN_HOFFSET"])
    bad = []

    # ---- where core_v11 put its West pins (io_place on the core die)
    n_core = pin_tracks(ch)
    west = io_slots(sides["#W"], n_core)
    if a.check_def:
        real = def_west_pins(a.check_def)
        diff = [p for p, k in west.items() if p not in real or abs(real[p] - track_y(k)) > 0.005]
        if diff or len(real) != len(west):
            bad.append(f"West pins computed from pin_order.cfg differ from {a.check_def}: "
                       f"{len(diff)} pins, e.g. {diff[:3]}; DEF has {len(real)}, computed {len(west)}")
        else:
            print(f"core_v11 West pins: all {len(west)} computed positions = {os.path.basename(a.check_def)}")

    # ---- geometry
    dx = snap_up(a.shell_x + a.shell_w + a.shell_gap, M2)
    dy = round(a.dy_pitches * hpitch, 2)
    if abs(dy / SITE_H - round(dy / SITE_H)) > 1e-6:
        bad.append(f"DY {dy} is not on the site-row grid")
    sx, sy, sw, sh = a.shell_x, CORE_M, a.shell_w, a.shell_h
    if abs(sy / P_STEP - round(sy / P_STEP)) > 1e-6:
        bad.append("macro y not on the 1.36 um pin-track grid")
    ip_w, ip_h = round(cw + dx, 2), round(ch + dy, 2)
    g_dy = int(round(dy / P_STEP))           # pin-track offset core_v11 -> IP
    g_sy = int(round(sy / P_STEP))           # pin-track of the macro's local 0
    n_shell = pin_tracks(sh)
    n_die = pin_tracks(ip_h)

    def loc(j_core):          # core_v11 pin-track -> macro-local pin-track
        return j_core + g_dy - g_sy

    # ---- macro, East edge (core side)
    ren = {"i_rst_n": "o_core_rst_n", "i_clk": None}
    east, westm = {}, {}
    for p, j in west.items():
        if p in ren:
            q = ren[p]
        elif p.startswith("i_cfg_"):
            q = "o_" + p[2:]
        elif re.match(r"i_(weight|feature)_(data\[\d+\]|valid|last)$", p):
            q = "o_" + p[2:]
        elif re.match(r"o_(weight|feature)_ready$", p):
            q = "i_" + p[2:]
        else:
            bad.append(f"core_v11 West pin {p}: no macro pin for it")
            continue
        if q:
            east[q] = loc(j)
    clk_slot = loc(west["i_clk"])
    top_core = max(east.values())
    # result bus: bottom of the East edge, bit 0 lowest
    res = bits("i_result_data", 256) + ["i_result_valid", "i_result_last", "o_result_ready"]
    rstrb = {}                                  # result_axis_tstrb[b] -> track (West only)
    if a.result_top > 0:
        # spread up to --result-top (macro-local um): the 256 data bits with one tstrb
        # after every 8 (West edge only), then valid/last/ready, evenly over the tracks
        seq = []
        for b in range(32):
            seq += [f"i_result_data[{8 * b + i}]" for i in range(8)] + [f"tstrb{b}"]
        seq += res[256:]
        top = int(math.floor((a.result_top - T_ORG) / P_STEP))
        step = (top - a.result_track) / (len(seq) - 1)
        if step < 1:
            bad.append(f"--result-top {a.result_top}: {len(seq)} result pins do not fit")
            step = 1
        for i, p in enumerate(seq):
            k = a.result_track + int(round(i * step))
            if p.startswith("tstrb"):
                rstrb[int(p[5:])] = k
            else:
                east[p] = k
    else:
        for k, p in enumerate(res):
            east[p] = a.result_track + k
    east["S_AXI_ACLK"] = top_core + 10

    # ---- macro, West edge (AXI side): same track as the core-side bit
    for s in ("feature", "weight"):
        for b in range(256):
            westm[f"{s}_axis_tdata[{b}]"] = east[f"o_{s}_data[{b}]"]
        for b in range(32):
            westm[f"{s}_axis_tstrb[{b}]"] = east[f"o_{s}_data[{8 * b}]"] + 3
        westm[f"{s}_axis_tvalid"] = east[f"o_{s}_valid"]
        westm[f"{s}_axis_tlast"] = east[f"o_{s}_last"]
        westm[f"{s}_axis_tready"] = east[f"i_{s}_ready"]
    for b in range(256):
        westm[f"result_axis_tdata[{b}]"] = east[f"i_result_data[{b}]"]
    westm["result_axis_tvalid"] = east["i_result_valid"]
    westm["result_axis_tlast"] = east["i_result_last"]
    westm["result_axis_tready"] = east["o_result_ready"]
    rtop = a.result_track + len(res) - 1
    for b in range(32):
        westm[f"result_axis_tstrb[{b}]"] = rstrb[b] if rstrb else rtop + 6 + b
    ctl = ["S_AXI_ARESETN"] + [p.replace("\\", "") for p in axil_pins(AXI_ADDR)]
    for k, p in enumerate(ctl):
        westm[p] = clk_slot - 4 + 2 * k
    if westm["S_AXI_ARESETN"] <= east["i_feature_ready"] and westm["S_AXI_ARESETN"] <= east["i_weight_ready"]:
        bad.append("AXI4-Lite group runs into the stream group")
    if max(westm.values()) >= min(v for p, v in east.items() if p.startswith(("o_weight_data", "o_feature_data"))) \
            and max(v for p, v in westm.items() if p.startswith("result_axis")) >= \
            min(v for p, v in east.items() if p.startswith(("o_weight_data", "o_feature_data"))):
        bad.append("result group runs into the stream group")

    # clock-gate groups (GEMM_CG_GROUPS): each group is a run of adjacent bits of
    # a data bank, so it is compact on the macro only if the pins of each bus
    # follow the bit order along the edge
    order_note = []
    for bus, side in (("o_weight_data", east), ("o_feature_data", east), ("i_result_data", east),
                      ("weight_axis_tdata", westm), ("feature_axis_tdata", westm),
                      ("result_axis_tdata", westm)):
        ks = [side[f"{bus}[{b}]"] for b in range(256)]
        inc = all(ks[i] < ks[i + 1] for i in range(255))
        dec = all(ks[i] > ks[i + 1] for i in range(255))
        if not (inc or dec):
            bad.append(f"{bus}: pins not in bit order along the edge (clock-gate groups would not be compact)")
        order_note.append(f"{bus} {'up' if inc else 'down' if dec else 'MIXED'}")

    shell_e = exact_side(east, n_shell)
    shell_w = exact_side(westm, n_shell)

    # ---- die pins: West, the macro's West pin on the same track; clock above the macro
    diepos = {p: k + g_sy for p, k in westm.items()}
    diepos["S_AXI_ACLK"] = int(math.ceil((sy + sh + a.clk_above - T_ORG) / P_STEP))
    die_w = exact_side(diepos, n_die)

    # ---- check every alignment through io_place itself
    pe, pw, pd = io_slots(shell_e, n_shell), io_slots(shell_w, n_shell), io_slots(die_w, n_die)
    for p, j in west.items():                       # core side: y of core_v11 + DY
        q = "o_core_rst_n" if p == "i_rst_n" else None if p == "i_clk" else \
            ("o_" + p[2:] if p.startswith("i_") else "i_" + p[2:])
        if q and abs(sy + track_y(pe[q]) - (track_y(j) + dy)) > 0.005:
            bad.append(f"{q}: y {sy + track_y(pe[q]):.2f} != core_v11 {p} {track_y(j):.2f} + DY")
    for p, k in pw.items():                         # die pin = macro West pin
        if abs(track_y(pd[p]) - (sy + track_y(k))) > 0.005:
            bad.append(f"die pin {p} at y {track_y(pd[p]):.2f}, macro pin at {sy + track_y(k):.2f}")
    straight = 0
    for p, k in pw.items():
        m = re.match(r"(feature|weight)_axis_tdata\[(\d+)\]$", p) or re.match(r"(result)_axis_tdata\[(\d+)\]$", p)
        if m:
            q = f"i_result_data[{m.group(2)}]" if m.group(1) == "result" else f"o_{m.group(1)}_data[{m.group(2)}]"
            straight += pe[q] == k
    if straight != 768:
        bad.append(f"only {straight}/768 AXIS data bits cross the macro on one track")

    # ---- macros of the IP
    place = []
    for n, x, y, o in macros:
        place.append((PREFIX + n, round(x + dx, 2), round(y + dy, 2), o))
    place.append((SHELL_INST, sx, sy, "N"))

    size = {}
    srams = [(x, y) for n, x, y, o in place if "u_macro" in n]
    rows = sorted([(x, y) for n, x, y, o in place if n.endswith("u_row")], key=lambda t: -t[1])
    obs_core = env.get("GEMM_SRAM_MET5_OBS", "")
    sram_wh = None
    m = re.match(r"met5 ([\d.]+) ([\d.]+) ([\d.]+) ([\d.]+)", obs_core)
    if m:
        v = list(map(float, m.groups()))
        sram_wh = (round(v[2] - v[0], 2), round(v[3] - v[1], 2))
    row_wh = None
    if a.row_lef and os.path.exists(a.row_lef):
        row_wh = lef_size(a.row_lef, "ProcessingElementRow")
    if not row_wh:
        g = re.search(r"row macro\s*:\s*([\d.]+)\s*x\s*([\d.]+)", open(a.geometry).read()) if a.geometry else None
        row_wh = (float(g.group(1)), float(g.group(2))) if g else None
    if not (sram_wh and row_wh):
        raise SystemExit("cannot size the SRAM / row macros (give --row-lef or --geometry)")
    for n, x, y, o in place:
        size[n] = (sw, sh) if n == SHELL_INST else row_wh if n.endswith("u_row") else sram_wh

    for n, x, y, o in place:
        w, h = size[n]
        if x < CORE_X - 1e-6 or y < CORE_M - 1e-6 or x + w > ip_w - CORE_X + 1e-6 or y + h > ip_h - CORE_M + 1e-6:
            bad.append(f"outside the core area: {n}")
        if abs((y - CORE_M) / SITE_H - round((y - CORE_M) / SITE_H)) > 1e-6:
            bad.append(f"off the site-row grid: {n} y={y}")
    for i in range(len(place)):
        n1, x1, y1, _ = place[i]
        w1, h1 = size[n1]
        for j in range(i + 1, len(place)):
            n2, x2, y2, _ = place[j]
            w2, h2 = size[n2]
            if x1 < x2 + w2 - 1e-6 and x2 < x1 + w1 - 1e-6 and y1 < y2 + h2 - 1e-6 and y2 < y1 + h1 - 1e-6:
                bad.append(f"overlap: {n1} / {n2}")
    gap_e = min(x for n, x, y, o in place if n != SHELL_INST) - (sx + sw)
    if gap_e < 10.0:
        bad.append(f"only {gap_e:.2f} um between the AXI macro and the next macro")

    # ---- PDN: same pitch; met5 phase unchanged (DY = k x pitch), met4 phase moved with DX
    hoff_ip = round((hoff + dy) % hpitch, 2)
    voff_ip = round((VOFFSET + dx) % VPITCH, 2)
    core_top = ip_h - CORE_M

    def pairs():
        c = CORE_M + hoff_ip
        while c < core_top:
            yield (c - HW / 2, c + HW + HS + HW / 2)
            c += hpitch

    def n_pairs(lo, hi, slack):
        return sum(1 for p0, p1 in pairs() if p0 >= lo + slack and p1 <= hi - slack)

    keep = float(env["FP_PDN_HORIZONTAL_HALO"]) + 0.3
    if not n_pairs(rows[0][1] + row_wh[1] + keep, core_top, 1.0):
        bad.append("band above row 0 has no met5 pair")
    for i in range(len(rows) - 1):
        if not n_pairs(rows[i + 1][1] + row_wh[1] + keep, rows[i][1] - keep, 1.0):
            bad.append(f"channel {i}/{i + 1}: no met5 pair")
    for n, x, y, o in place:
        w, h = size[n]
        lo, hi = (y + CORE_M, y + h - CORE_M) if n.endswith("u_row") else \
            (y + 4.76, y + 411.78) if "u_macro" in n else (y + CORE_M, y + h - CORE_M)
        want = 1 if n.endswith("u_row") else 2 if "u_macro" in n else 50
        if n_pairs(lo, hi, 0.5) < want:
            bad.append(f"too few met5 pairs over the power pins of {n}")
    # cells west of the AXI macro need a tap column clear of its tap halo (ip_v2: a
    # 20.24 um band got no tap at all, so its wells floated and LVS failed)
    band = sx - 12 * 0.46                    # core starts 5.52 um from the die edge
    need = float(env["FP_TAP_HORIZONTAL_HALO"]) + 2 * float(env.get("FP_TAPCELL_DIST", 13))
    if band < need:
        bad.append(f"band west of the AXI macro {band:.2f} um < {need:.2f} (tap halo + 2 x tap distance)")
    n_expect = int(env.get("GEMM_CORE_MACROS", 112)) + 1
    if len(place) != n_expect:
        bad.append(f"{len(place)} macros, expected {n_expect}")

    if bad:
        print("IP floorplan check FAILED:\n  " + "\n  ".join(bad[:40]))
        return 1

    # ---- write
    ds, di = os.path.join(a.out, "gemm_ip_shell"), os.path.join(a.out, "gemm_ip")
    os.makedirs(ds, exist_ok=True)
    os.makedirs(di, exist_ok=True)
    with open(os.path.join(ds, "pin_order.cfg"), "w") as f:
        f.write("#W\n" + "\n".join(shell_w) + "\n#E\n" + "\n".join(shell_e) + "\n")
    with open(os.path.join(ds, "sizes.tcl"), "w") as f:
        f.write("# generated by gen_ip_files.py - do not edit, rerun the script\n")
        f.write(f"set ::env(FP_SIZING) absolute\nset ::env(DIE_AREA) \"0 0 {sw:.2f} {sh:.2f}\"\n")
        f.write("# met4 power straps every 40 um (default 153.6 would leave one pair on a\n"
                "# 160 um wide block); the IP's met5 straps cross them every 51.68 um\n"
                "set ::env(FP_PDN_VPITCH)  40\nset ::env(FP_PDN_VOFFSET) 10\n")
    with open(os.path.join(di, "macro.cfg"), "w") as f:
        f.write("# instance  x  y  orientation   (generated by gen_ip_files.py:"
                f" core_v11 floorplan moved by {dx:.2f}, {dy:.2f} + the AXI macro)\n")
        for n, x, y, o in place:
            f.write(f"{n.replace('[', chr(92) + '[').replace(']', chr(92) + ']')} {x:.2f} {y:.2f} {o}\n")
    obs = ", ".join(f"met5 {x:.2f} {y:.2f} {x + sram_wh[0]:.2f} {y + sram_wh[1]:.2f}" for x, y in srams)
    with open(os.path.join(di, "sizes.tcl"), "w") as f:
        f.write("# generated by gen_ip_files.py - do not edit, rerun the script\n")
        f.write(f"set ::env(FP_SIZING) absolute\nset ::env(DIE_AREA) \"0 0 {ip_w:.2f} {ip_h:.2f}\"\n")
        f.write(f"# PDN: pitches of core_v11; offsets so every strap sits where it was\n"
                f"# relative to the rows and SRAMs (core moved by {dx:.2f}, {dy:.2f})\n")
        for k in ("FP_PDN_HORIZONTAL_HALO", "FP_PDN_VERTICAL_HALO", "FP_TAP_HORIZONTAL_HALO",
                  "FP_TAP_VERTICAL_HALO", "FP_PDN_HWIDTH", "FP_PDN_HSPACING", "FP_PDN_HPITCH"):
            f.write(f"set ::env({k}) {env[k]}\n")
        f.write(f"set ::env(FP_PDN_HOFFSET)  {hoff_ip:.2f}\n")
        f.write(f"set ::env(FP_PDN_VPITCH)   {VPITCH}\nset ::env(FP_PDN_VOFFSET)  {voff_ip:.2f}\n")
        f.write(f"# expected hard macros (checked by run_flow.sh)\nset ::env(GEMM_CORE_MACROS) {len(place)}\n")
        f.write(f"set ::env(GEMM_IP_MACROS) {len(place)}\n")
        f.write(f"# met5 over each of the {len(srams)} SRAM macros (routing obstruction, see gemm_core/config.tcl)\n"
                f"set ::env(GEMM_SRAM_MET5_OBS) \"{obs}\"\n")
    with open(os.path.join(di, "pin_order.cfg"), "w") as f:
        f.write("#W\n" + "\n".join(die_w) + "\n")
    lines = [
        f"IP die    : {ip_w:.2f} x {ip_h:.2f} um = {ip_w * ip_h / 1e6:.2f} mm2 "
        f"(core_v11 {cw:.2f} x {ch:.2f} = {cw * ch / 1e6:.2f} mm2, +{100 * (ip_w * ip_h / (cw * ch) - 1):.1f} %)",
        f"core moved: DX {dx:.2f} um, DY {dy:.2f} um ({a.dy_pitches} met5 pitches)",
        f"AXI macro : {SHELL_INST} {sw:.2f} x {sh:.2f} um at ({sx:.2f}, {sy:.2f}); "
        f"{gap_e:.2f} um to the next macro",
        f"macros    : {len(place)} = {len(rows)} rows + {len(srams)} SRAM + 1 AXI macro",
        f"PDN       : met5 pitch {hpitch} offset {hoff_ip:.2f} (core_v11 {hoff}); met4 pitch {VPITCH} "
        f"offset {voff_ip:.2f} (core_v11 {VOFFSET})",
        f"macro pins: W {len(westm)}, E {len(east)} ({len(east) - 260} at the core_v11 West y + DY, "
        f"259 result at y {sy + track_y(min(east[p] for p in res)):.2f}..{sy + track_y(max(east[p] for p in res)):.2f}"
        f" (macro-local {track_y(min(east[p] for p in res)):.2f}..{track_y(max(east[p] for p in res)):.2f}), clock at "
        f"{sy + track_y(east['S_AXI_ACLK']):.2f}); 768/768 AXIS data bits on one track",
        "bit order : " + ", ".join(order_note) + " (each bus monotonic in the bit index along the edge: clock-gate groups of adjacent bits are compact)",
        f"die pins  : W {len(diepos)} (all on the track of their macro pin; S_AXI_ACLK at "
        f"y {track_y(diepos['S_AXI_ACLK']):.2f}, macro top {sy + sh:.2f})",
    ]
    txt = "\n".join(lines) + "\n"
    open(os.path.join(di, "floorplan.txt"), "w").write(txt)
    print(txt + f"written under {ds} and {di}  (floorplan + pin alignment checks OK)")
    return 0


# ---------------------------------------------------------------------------
def rtl(a):
    """GEMM_top for the IP run (no #(...) on the macro instance) and the port
    view of the hardened GemmAxiShell, both from what exists on disk"""
    di = os.path.join(a.out, "gemm_ip")
    os.makedirs(di, exist_ok=True)
    s = open(os.path.join(HERE, "..", "rtl_asic", "axi", "GEMM_top.v")).read()
    s, n = re.subn(r"\bGemmAxiShell\s*#\s*\((?:[^()]|\([^()]*\))*\)", "GemmAxiShell", s, count=1)
    if n != 1:
        raise SystemExit("gen_ip_files.py: no GemmAxiShell #(...) instance in GEMM_top.v")
    hdr = ("// generated by openlane/gen_ip_files.py from rtl_asic/axi/GEMM_top.v: the\n"
           "// GemmAxiShell instance has no parameter override (it is the hard macro\n"
           "// u_axi_shell, built lean + clock gating). Do not edit.\n")
    open(os.path.join(di, "GEMM_top_ip.v"), "w").write(hdr + s)

    nl = open(a.rtl).read()
    m = re.search(r"module\s+GemmAxiShell\s*\((.*?)\);(.*?)\bendmodule", nl, re.S)
    if not m:
        raise SystemExit(f"no module GemmAxiShell in {a.rtl}")
    order = [p.strip() for p in m.group(1).replace("\n", " ").split(",") if p.strip()]
    decl = {}
    for d, w, names in re.findall(r"^\s*(input|output|inout)\s*(\[[^\]]+\])?\s*([^;]+);", m.group(2), re.M):
        for nm in names.split(","):
            decl[nm.strip()] = (d, w)
    ports = [p for p in order if p in decl and p not in ("vccd1", "vssd1", "VPWR", "VGND")]
    def width(w):
        r = re.match(r"\[\s*(\d+)\s*:\s*(\d+)\s*\]", w or "")
        return abs(int(r.group(1)) - int(r.group(2))) + 1 if r else 1
    bits = sum(width(decl[p][1]) for p in ports)
    if bits < 1700:
        raise SystemExit(f"only {len(ports)} ports ({bits} bits) read from {a.rtl}")
    out = ["/// sta-blackbox",
           "// Port-only view of the hardened AXI macro (gemm_ip_shell), generated by",
           f"// openlane/gen_ip_files.py from {os.path.basename(a.rtl)}. Same use as",
           "// gemm_core/sram_bb.v: synthesis and lint keep the instance, STA takes",
           "// the macro from its .lib.",
           "(* blackbox *)",
           "module GemmAxiShell ("]
    body = []
    if any(p in decl for p in ("vccd1", "vssd1")):
        body += ["`ifdef USE_POWER_PINS", "    inout vccd1,", "    inout vssd1,", "`endif"]
    for i, p in enumerate(ports):
        d, w = decl[p]
        body.append(f"    {d:6s} {w + ' ' if w else ''}{p}{',' if i < len(ports) - 1 else ''}")
    out += body + [");", "endmodule", ""]
    open(os.path.join(di, "GemmAxiShell_bb.v"), "w").write("\n".join(out))
    print(f"wrote {di}/GEMM_top_ip.v and GemmAxiShell_bb.v ({len(ports)} ports, {bits} bits)")
    return 0


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--pe-area", type=float)
    ap.add_argument("--core-args", default="--layout v3 --b-wide --b-gap-y 200 --strip 1000 --a-gap-x 200",
                    help="gen_core_files.py floorplan options of the core run to reuse (core_v11)")
    ap.add_argument("--check-def", help="final DEF of that core run: the computed West pins must match it")
    ap.add_argument("--row-lef", help="LEF of the row macro (size)")
    ap.add_argument("--geometry", help="openlane/state/geometry.txt (row size if no --row-lef)")
    ap.add_argument("--shell-x", type=float, default=51.52,
                    help="x of the AXI macro (um); the band west of it must hold a tap column")
    ap.add_argument("--shell-w", type=float, default=160.08, help="width of the AXI macro (um)")
    ap.add_argument("--shell-h", type=float, default=5932.32, help="height of the AXI macro (um)")
    ap.add_argument("--shell-gap", type=float, default=0.0,
                    help="extra gap east of the macro (the core keeps its own 65.8 um West band)")
    ap.add_argument("--dy-pitches", type=int, default=5, help="DY = this many met5 pitches")
    ap.add_argument("--result-track", type=int, default=15, help="macro pin-track of i_result_data[0]")
    ap.add_argument("--result-top", type=float, default=0.0,
                    help="spread the result pins (both macro edges) from --result-track up to this "
                         "macro-local y (um); 0 = one per pin-track from --result-track")
    ap.add_argument("--clk-above", type=float, default=27.0, help="die clock pin this far above the macro (um)")
    ap.add_argument("--rtl", help="final GemmAxiShell netlist: write the IP top + macro port view")
    ap.add_argument("--out", default=os.path.join(HERE, "designs"))
    a = ap.parse_args()
    if a.rtl:
        return rtl(a)
    if not a.pe_area:
        ap.error("give --pe-area (openlane/state/pe_area.txt)")
    a.core_args = a.core_args.split()
    return floorplan(a)


if __name__ == "__main__":
    sys.exit(main())
