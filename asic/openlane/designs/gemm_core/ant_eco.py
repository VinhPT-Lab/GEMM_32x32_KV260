#!/usr/bin/env python3
"""
ant_eco.py - targeted diode insertion from an OpenROAD ARC violator report.

Run by resume.tcl through OpenLane's manipulate_layout (openroad -python),
on the database from BEFORE global routing (after the heuristic diodes), so
the next global + detailed route connects the new diodes:

  ant_eco.py --violators <antenna_violators.rpt> [--tag 1] [--margin 0.15]
             --input-lef <merged.lef> --output <out.odb> --output-def <out.def> <in.odb>

Every violating island of the report (ARC lists each gate of an island on
its own line: same net, layer and partial area) gets diodes next to one of
its gates:
  - Required ~400 (no diffusion in the island: the diode that is on the net
    was wired to it through a higher layer): 1 diode abutting the gate on
    the side of its input pin, more if one diode's limit is still too low;
  - Required > 400 (diode/driver already in the island, wire just too
    long): as many extra diodes as the PWL rule needs - in sky130 one diode
    lifts the metal limit from 400 to ~2774, each further one only by ~174.
Instances named in the report that do not exist in this database (diodes
added later by the global router) are traced back to the pin they protect.
New diodes are called ANTFIX<tag>_<cell>_<pin>_<n> and still need
legalizing (resume.tcl runs detailed placement right after).
"""
import math
import os
import re
import sys

import click

sys.path.insert(0, os.path.join(os.environ.get("SCRIPTS_DIR", ""), "odbpy"))
import odb  # noqa: E402
from reader import click_odb  # noqa: E402
from diodes import DiodeInserter  # noqa: E402

LINE = re.compile(r"Partial/Required:\s*([\d.]+),\s*Required:\s*([\d.]+),\s*Partial:\s*([\d.]+),"
                  r"\s*Net:\s*(\S+),\s*Pin:\s*(\S+?)/(\S+),\s*Layer:\s*(\S+)")


def read_report(path):
    """[(net, inst, pin, layer, ratio, required, partial)] from an ARC violator report"""
    out = []
    for line in open(path, errors="ignore"):
        m = LINE.search(line)
        if m:
            ratio, req, part = float(m.group(1)), float(m.group(2)), float(m.group(3))
            out.append((m.group(4), m.group(5), m.group(6), m.group(7), ratio, req, part))
    return out


def diodes_needed(required, partial, margin, first_limit, gain, cap):
    want = partial * (1.0 + margin)
    if required <= 400.5:
        n = 1 if want <= first_limit else 1 + math.ceil((want - first_limit) / gain)
    else:
        n = max(1, math.ceil((want - required) / gain))
    return min(n, cap)


class Eco:
    def __init__(self, block, diode_cell, diode_pin, tag, verbose):
        self.block = block
        self.di = DiodeInserter(block, diode_cell=diode_cell, diode_pin=diode_pin, side_strategy="pin")
        self.diode_cell = diode_cell
        self.diode_pin = diode_pin
        self.tag = tag
        self.verbose = verbose
        self.added = 0

    def is_diode(self, inst):
        return inst.getMaster().getConstName() == self.diode_cell

    def decode_diode_name(self, name):
        """ANTENNA_<inst>_<pin> / ANTFIX<k>_<inst>_<pin>_<n> -> the iterm it protects, or None"""
        m = re.match(r"^(?:ANTENNA|ANTFIX\d*|INSDIODE\d*)_(.*)$", name)
        if not m:
            return None
        rest = m.group(1)
        if name.startswith("ANTFIX"):
            rest = re.sub(r"_\d+$", "", rest)
        for i in range(len(rest) - 1, 0, -1):
            if rest[i] != "_":
                continue
            inst = self.block.findInst(rest[:i])
            if inst is None:
                continue
            it = inst.findITerm(rest[i + 1:])
            if it is not None:
                return it
        return None

    def resolve(self, entries):
        """pick the iterm to put the diodes next to, for one island"""
        gates, diodes, ghosts = [], [], []
        for net, inst_name, pin, *_ in entries:
            inst = self.block.findInst(inst_name)
            if inst is None:
                ghosts.append(inst_name)
                continue
            it = inst.findITerm(pin)
            if it is None:
                continue
            (diodes if self.is_diode(inst) else gates).append(it)
        if gates:
            return gates[0]
        if diodes:
            return diodes[0]
        for g in ghosts:
            it = self.decode_diode_name(g)
            if it is not None:
                return it
        net = self.block.findNet(entries[0][0])
        if net is not None:
            for it in net.getITerms():
                if it.isInputSignal() and not self.is_diode(it.getInst()):
                    return it
        return None

    def unique(self, base):
        name, k = base, 0
        while self.block.findInst(name) is not None:
            k += 1
            name = f"{base}_{k}"
        return name

    def add_diodes(self, it, net, n):
        inst = it.getInst()
        site = inst.getMaster().getSite()
        px, py = self.di.pin_position(it)
        for k in range(n):
            if site is not None and site.getConstName() == self.di.diode_site:
                dx, dy, do = self.di.place_diode_stdcell(it, px, py, None)
            else:
                dx, dy, do = self.di.place_diode_macro(it, px, py, None)
            name = self.unique(f"ANTFIX{self.tag}_{inst.getConstName()}_{it.getMTerm().getConstName()}_{k}")
            d = odb.dbInst_create(self.block, self.di.diode_master, name)
            d.setOrient(do)
            d.setLocation(dx, dy)
            d.setPlacementStatus("PLACED")
            d.findITerm(self.diode_pin).connect(net)
            self.added += 1


@click.command()
@click.option("--violators", required=True, help="ARC antenna_violators.rpt of a routed run of this netlist")
@click.option("--tag", default="1", help="goes into the new instance names")
@click.option("--diode-cell", default="sky130_fd_sc_hd__diode_2")
@click.option("--diode-pin", default="DIODE")
@click.option("--margin", type=float, default=0.15, help="aim this much below the limit")
@click.option("--first-limit", type=float, default=2600.0,
              help="metal limit with one diode in the island (sky130 diode_2: 2774)")
@click.option("--gain", type=float, default=165.0, help="limit gained per further diode (sky130 diode_2: 174)")
@click.option("--max-per-island", type=int, default=8)
@click.option("--max-total", type=int, default=3000)
@click.option("-v", "--verbose", is_flag=True)
@click_odb
def main(reader, violators, tag, diode_cell, diode_pin, margin, first_limit, gain,
         max_per_island, max_total, verbose):
    block = reader.block
    rows = read_report(violators)
    print(f"ant_eco: {len(rows)} violating pins in {violators}")
    islands = {}
    for r in rows:
        islands.setdefault((r[0], r[3], round(r[6], 2)), []).append(r)
    eco = Eco(block, diode_cell, diode_pin, tag, verbose)
    skipped = []
    for key in sorted(islands, key=lambda k: -max(e[4] for e in islands[k])):
        entries = islands[key]
        net = block.findNet(key[0])
        if net is None:
            skipped.append(f"{key[0]}: net not in this database")
            continue
        it = eco.resolve(entries)
        if it is None:
            skipped.append(f"{key[0]}: no pin to put a diode next to")
            continue
        req = max(e[5] for e in entries)
        part = max(e[6] for e in entries)
        n = diodes_needed(req, part, margin, first_limit, gain, max_per_island)
        if eco.added + n > max_total:
            skipped.append(f"{key[0]}: over --max-total {max_total}")
            continue
        eco.add_diodes(it, net, n)
        print(f"  {n} diode(s)  {key[0]} {key[1]} required {req:.0f} partial {part:.0f}"
              f"  next to {it.getInst().getConstName()}/{it.getMTerm().getConstName()}")
    for s in skipped:
        print(f"  skipped {s}")
    print(f"ant_eco: {eco.added} diodes added on {len(islands) - len(skipped)} of {len(islands)} islands "
          f"({len(skipped)} skipped)")


if __name__ == "__main__":
    main()
