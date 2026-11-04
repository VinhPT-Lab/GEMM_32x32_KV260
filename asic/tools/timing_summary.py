#!/usr/bin/env python3
"""
timing_summary.py <run dir>
Summarise the signoff (rcx) STA of an OpenLane v1 run: violating paths grouped
by where they start and end, plus the worst setup and hold path, trimmed.
"""
import glob, os, re, sys, collections

run = sys.argv[1]
def newest(pat):
    f = sorted(glob.glob(os.path.join(run, "reports/signoff", pat)))
    return f[-1] if f else None

def kind(pin):
    p = pin.replace("\\", "")
    m = re.search(r"g_pe_row\[(\d+)\]\.u_row(?:/(\w+))?", p)
    if m:
        return f"row pin {m.group(2)}" if m.group(2) else "row macro (launch)"
    if "u_feature_skew" in p:
        return "FeatureSkew flop"
    if "u_output_deskew" in p:
        return "OutputDeskew flop"
    if re.fullmatch(r"_\d+_(/\w+)?", p):
        return "top-level flop (FeatureSkew/OutputDeskew)"
    if "/" not in p:
        return "port " + re.sub(r"\[.*", "", p)
    return "other: " + p.split("/")[0][:40]

def paths(fn):
    txt = open(fn, errors="replace").read()
    for blk in re.split(r"\n(?=Startpoint: )", "\n" + txt)[1:]:
        s = re.search(r"Startpoint: (\S+)", blk).group(1)
        e = re.search(r"Endpoint: (\S+)", blk)
        sl = re.search(r"(-?\d+\.\d+)\s+slack \((VIOLATED|MET)\)", blk)
        if e and sl:
            yield s, e.group(1), float(sl.group(1)), blk

for label, pat in (("HOLD (min)", "*rcx_sta.min.rpt"), ("SETUP (max)", "*rcx_sta.max.rpt")):
    fn = newest(pat)
    print(f"\n==================== {label}: {fn and os.path.basename(fn)}")
    if not fn:
        continue
    P = list(paths(fn))
    bad = [p for p in P if p[2] < 0]
    print(f"paths listed: {len(P)}  violating: {len(bad)}  (report lists at most 1000)")
    grp = collections.defaultdict(list)
    for s, e, sl, _ in bad:
        grp[(kind(s), kind(e))].append(sl)
    for (ks, ke), v in sorted(grp.items(), key=lambda kv: min(kv[1])):
        print(f"  {len(v):5d}  worst {min(v):7.2f}   {ks:30s} -> {ke}")
    if P:
        s, e, sl, blk = min(P, key=lambda p: p[2])
        print(f"\n  worst path: {s}\n           -> {e}   slack {sl}")
        keep = []
        for line in blk.splitlines():
            t = line.strip()
            if re.match(r"^-?\d+\.\d+", t) or "clock" in t or "slack" in t or "library" in t:
                keep.append("    " + re.sub(r"\s+", " ", t)[:150])
        print("\n".join(keep[:60]))
