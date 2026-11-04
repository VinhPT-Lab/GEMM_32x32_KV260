#!/usr/bin/env python3
"""Compare two defsum outputs: report component / net / routing differences.
usage: defcmp.py a.tsv b.tsv [changed_nets_out]"""
import sys
def load(p):
    C, N = {}, {}
    for l in open(p):
        t = l.rstrip('\n').split('\t')
        if t[0] == 'C': C[t[1]] = tuple(t[2:])
        else: N[t[1]] = tuple(t[2:])
    return C, N
Ca, Na = load(sys.argv[1]); Cb, Nb = load(sys.argv[2])
print(f'components: a {len(Ca)} b {len(Cb)}; only a {len(set(Ca)-set(Cb))}, only b {len(set(Cb)-set(Ca))}, '
      f'master/placement changed {sum(1 for k in set(Ca)&set(Cb) if Ca[k]!=Cb[k])}')
moved = [k for k in set(Ca)&set(Cb) if Ca[k]!=Cb[k]]
print('  e.g. changed:', moved[:3], 'only b:', sorted(set(Cb)-set(Ca))[:3])
common = set(Na)&set(Nb)
pins = [k for k in common if Na[k][:2]!=Nb[k][:2]]
route = [k for k in common if Na[k][3]!=Nb[k][3]]
routed_a = sum(1 for k in Na if Na[k][3] != '-')
print(f'nets: a {len(Na)} (routed {routed_a}) b {len(Nb)}; only a {len(set(Na)-set(Nb))}, only b {len(set(Nb)-set(Na))}; '
      f'pin set changed {len(pins)}; routing changed {len(route)} ({100*len(route)/max(1,routed_a):.2f} % of routed nets)')
print('  e.g. routing changed:', sorted(route)[:5])
if len(sys.argv) > 3:
    open(sys.argv[3],'w').write('\n'.join(sorted(set(route)|set(pins)|(set(Nb)-set(Na))))+'\n')
