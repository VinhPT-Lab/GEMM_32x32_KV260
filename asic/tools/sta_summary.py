#!/usr/bin/env python3
"""
sta_summary.py <rcx_sta.max.rpt | rcx_sta.min.rpt> [--worst N] [--skip REGEX]

Short summary of an OpenSTA path report from OpenLane signoff:
  - how many paths are listed / violate (I/O-boundary paths counted apart),
  - violating internal paths grouped by what they go through (an OpenRAM
    pin, a row macro pin, the named nets on the way: u_output_buffer, ...),
  - the worst internal path in full.
--skip REGEX leaves out the paths whose text matches (e.g. a group already
  understood) so the next problem shows up in full.
"""
import collections
import re
import sys


def blocks(text):
    parts = re.split(r"\n(?=Startpoint: )", "\n" + text)
    return [p for p in parts if p.startswith("Startpoint: ")]


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    worst_n = int(sys.argv[sys.argv.index("--worst") + 1]) if "--worst" in sys.argv else 5
    skip = sys.argv[sys.argv.index("--skip") + 1] if "--skip" in sys.argv else None
    args = [a for a in args if a not in (str(worst_n), skip)]
    if len(args) != 1:
        print(__doc__)
        return 2
    text = open(args[0], errors="ignore").read()
    paths = []
    for b in blocks(text):
        st = re.search(r"Startpoint: (\S+) \(([^)]*)\)", b)
        en = re.search(r"Endpoint: (\S+) \(([^)]*)\)", b)
        sl = re.search(r"(-?\d+\.\d+)\s+slack \((VIOLATED|MET)\)", b)
        if not (st and en and sl):
            continue
        port = "input port" in st.group(2) or "output port" in en.group(2)
        body = b
        if skip and re.search(skip, body):
            continue
        tags = set()
        if re.search(r"u_macro/(dout|din|addr|csb|web|wmask)", body):
            m = re.findall(r"(u_\w+)\.(?:\w+\.)*?g_bank\[\d+\]\.g_lane\[\d+\]\.u_macro/(\w+?)\d*\b", body)
            for owner, pin in m:
                tags.add(f"SRAM {owner}:{pin}")
            if not m:
                tags.add("SRAM pin")
        if "u_row/" in body:
            tags.add("row macro pin")
        for h in re.findall(r"\b(u_[a-z_]+)\.", body):
            tags.add(h)
        paths.append({"slack": float(sl.group(1)), "port": port, "start": st.group(1), "stype": st.group(2),
                      "end": en.group(1), "etype": en.group(2), "tags": tags, "text": b})
    if not paths:
        print("no paths found")
        return 1
    viol = [p for p in paths if p["slack"] < 0]
    inner = [p for p in viol if not p["port"]]
    print(f"{len(paths)} paths listed, {len(viol)} violate ({len(viol) - len(inner)} touch an I/O port, "
          f"{len(inner)} internal)")
    if not inner:
        print("no internal path violates")
        return 0
    s = sorted(p["slack"] for p in inner)
    print(f"internal: worst {s[0]:.2f} ns, median {s[len(s) // 2]:.2f} ns, sum {sum(s):.1f} ns over the listed paths")
    groups = collections.Counter()
    worst = {}
    for p in inner:
        key = " + ".join(sorted(t for t in p["tags"] if t.startswith(("SRAM", "row")))) or "no macro pin"
        names = sorted(t for t in p["tags"] if t.startswith("u_"))
        key += "   [" + ", ".join(names[:4]) + "]" if names else ""
        groups[key] += 1
        worst[key] = min(worst.get(key, 0.0), p["slack"])
    print("\nviolating internal paths by what they pass through:")
    for k, c in groups.most_common(12):
        print(f"  {c:6d}  worst {worst[k]:7.2f}  {k}")
    print(f"\nstart -> end types of the worst {worst_n}:")
    for p in sorted(inner, key=lambda p: p["slack"])[:worst_n]:
        print(f"  {p['slack']:7.2f}  {p['start']} ({p['stype']}) -> {p['end']} ({p['etype']})")
    w = min(inner, key=lambda p: p["slack"])
    print("\nworst internal path in full:")
    print(w["text"].rstrip()[:12000])
    return 0


if __name__ == "__main__":
    sys.exit(main())
