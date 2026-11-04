#!/usr/bin/env python3
"""lef_antenna_pins.py <macro.lef> [<macro name>]
Does every signal pin of a hard macro carry antenna data for the parent's
antenna check? Inputs need ANTENNAGATEAREA (the gates behind the pin),
outputs ANTENNADIFFAREA (the driver that discharges the parent's wire).
Power/ground pins are skipped. Prints the counts and the first pins without
data; exit 0 only if none is missing."""
import re
import sys


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        return 2
    want = sys.argv[2] if len(sys.argv) > 2 else None
    macro = pin = None
    pins = {}
    for raw in open(sys.argv[1], errors="ignore"):
        s = raw.strip()
        m = re.match(r"MACRO\s+(\S+)", s)
        if m:
            macro = m.group(1)
            continue
        if want and macro != want:
            continue
        m = re.match(r"PIN\s+(\S+)", s)
        if m:
            pin = m.group(1)
            pins[pin] = {"dir": None, "use": None, "gate": False, "diff": False}
            continue
        if pin is None:
            continue
        if re.match(r"END\s+" + re.escape(pin) + r"\s*$", s):
            pin = None
            continue
        m = re.match(r"DIRECTION\s+(\S+)", s)
        if m:
            pins[pin]["dir"] = m.group(1)
        m = re.match(r"USE\s+(\S+)", s)
        if m:
            pins[pin]["use"] = m.group(1)
        if s.startswith("ANTENNAGATEAREA"):
            pins[pin]["gate"] = True
        if s.startswith("ANTENNADIFFAREA"):
            pins[pin]["diff"] = True
    sig = {n: p for n, p in pins.items() if p["use"] not in ("POWER", "GROUND")}
    ins = [n for n, p in sig.items() if p["dir"] == "INPUT"]
    outs = [n for n, p in sig.items() if p["dir"] == "OUTPUT"]
    miss = [n for n in ins if not sig[n]["gate"]] + [n for n in outs if not sig[n]["diff"]]
    other = [n for n, p in sig.items() if p["dir"] not in ("INPUT", "OUTPUT")]
    print(f"{sys.argv[1]}: {len(ins)} inputs ({sum(sig[n]['gate'] for n in ins)} with ANTENNAGATEAREA, "
          f"{sum(sig[n]['diff'] for n in ins)} also ANTENNADIFFAREA), {len(outs)} outputs "
          f"({sum(sig[n]['diff'] for n in outs)} with ANTENNADIFFAREA), {len(other)} other signal pins")
    if miss:
        print(f"  {len(miss)} pins without antenna data, e.g. {miss[:8]}")
    return 1 if miss or not sig else 0


if __name__ == "__main__":
    sys.exit(main())
