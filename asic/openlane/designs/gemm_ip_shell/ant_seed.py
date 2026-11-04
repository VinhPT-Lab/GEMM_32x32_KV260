#!/usr/bin/env python3
"""
ant_seed.py - pins of the AXI macro that get an antenna diode right next to
them before the first global route (openroad -python, on the database after
the heuristic diodes):

  ant_seed.py --out <report> [--min-dist 40] [--extra <pins file>] <in.odb>

Writes the pins as an ARC antenna_violators.rpt (one island per pin, Required
400, Partial 500), the format gemm_core/ant_eco.py reads, so route_signoff.tcl
applies it as GEMM_ANT_ECO_RPT (one diode abutting each pin) before round 0.

Why (ip_shell, second try): every antenna violation after routing was a gate
pin with no diode in its island (Required 400), on a net of 20-120 um: the
port nets (port -> first hold buffer; the port diode joins the net through
another layer) and nets more than ~40 um from their driver. Each ECO round
after detailed routing fixed the listed pins and created others (4 -> 23,
3 -> 3), so the diodes go in before the first route instead. Chosen:
  - every input pin on a net driven by an input port,
  - every input pin more than --min-dist um (Manhattan) from its driver,
  - the pins listed in --extra (violators of earlier runs), if found.
"""
import argparse
import sys

import odb

DIODE = "sky130_fd_sc_hd__diode"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("odb")
    ap.add_argument("--out", required=True)
    ap.add_argument("--min-dist", type=float, default=40.0)
    ap.add_argument("--extra", help="file with inst/pin per line")
    a = ap.parse_args()
    db = odb.dbDatabase.create()
    odb.read_db(db, a.odb)
    b = db.getChip().getBlock()
    um = b.getDbUnitsPerMicron()
    extra = set()
    if a.extra:
        extra = {s.strip() for s in open(a.extra) if s.strip()}

    def pos(it):
        ok, x, y = it.getAvgXY()
        if ok:
            return x, y
        return tuple(it.getInst().getLocation())

    sel, n_port = [], 0
    for net in b.getNets():
        if net.getSigType() != "SIGNAL":
            continue
        drv, port = None, False
        for bt in net.getBTerms():
            if bt.getIoType() == "INPUT":
                ok, x, y = bt.getFirstPinLocation()
                if ok:
                    drv, port = (x, y), True
        if drv is None:
            for it in net.getITerms():
                if it.isOutputSignal():
                    drv = pos(it)
        if drv is None:
            continue
        for it in net.getITerms():
            if not it.isInputSignal() or it.getInst().getMaster().getConstName().startswith(DIODE):
                continue
            x, y = pos(it)
            d = (abs(x - drv[0]) + abs(y - drv[1])) / um
            pin = f"{it.getInst().getConstName()}/{it.getMTerm().getConstName()}"
            if port or d > a.min_dist or pin in extra:
                sel.append((d, pin, net.getConstName()))
                n_port += port
    sel.sort(key=lambda r: -r[0])
    with open(a.out, "w") as f:
        # distinct Partial per pin: ant_eco.py groups a report into islands by (net, layer, Partial)
        for k, (d, pin, net) in enumerate(sel):
            p = 500.0 + 0.01 * (len(sel) - k)
            f.write(f"Partial/Required:  {p / 400:.2f}, Required:    400.0, Partial:  {p:.2f}, "
                    f"Net: {net}, Pin: {pin}, Layer: met2\n")
    found = {s for _, s, _ in sel}
    print(f"ant_seed: {len(sel)} pins ({n_port} on input-port nets, "
          f"{sum(1 for r in sel if r[0] > a.min_dist)} more than {a.min_dist:g} um from the driver, "
          f"{len(extra & found)}/{len(extra)} listed) -> {a.out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
