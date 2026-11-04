#!/usr/bin/env python3
"""Summarise a DEF for comparison: components, nets (pins + routing hash).
usage: defsum.py in.def out.tsv   (out: C/N lines)"""
import sys, re, hashlib
src, out = sys.argv[1], sys.argv[2]
fo = open(out, 'w')
sec = None; buf = []
def flush_comp(s):
    t = s.split()
    # - name master + STATUS ( x y ) orient
    name, master = t[1], t[2]
    m = re.search(r'\+ (PLACED|FIXED|COVER|UNPLACED)\s*(?:\(\s*(-?\d+)\s+(-?\d+)\s*\)\s*(\S+))?', s)
    st = m.groups() if m else ('?',)
    fo.write('C\t%s\t%s\t%s\n' % (name, master, ' '.join(x for x in st if x)))
def flush_net(s):
    s = ' '.join(s.split())
    name = s.split()[1]
    head = s
    i = s.find(' + ')
    pins_part = s[:i] if i >= 0 else s
    pins = sorted(re.findall(r'\(\s*(\S+)\s+(\S+)\s*\)', pins_part))
    paths = []
    m = re.search(r'\+ (ROUTED|FIXED|COVER|NOSHIELD) ', s)
    if m:
        r = s[m.start():]
        r = re.split(r' \+ (?:USE|SOURCE|WEIGHT|PROPERTY|NONDEFAULTRULE)\b', r)[0]
        r = r[len(m.group(0)):]
        paths = sorted(p.strip() for p in r.split(' NEW '))
    h = hashlib.sha1('\n'.join(paths).encode()).hexdigest()[:16] if paths else '-'
    fo.write('N\t%s\t%d\t%s\t%d\t%s\n' % (name, len(pins), hashlib.sha1(repr(pins).encode()).hexdigest()[:12], len(paths), h))
with open(src) as f:
    for line in f:
        ls = line.strip()
        if sec is None:
            if ls.startswith('COMPONENTS '): sec = 'C'
            elif ls.startswith('NETS '): sec = 'N'
            continue
        if ls.startswith('END COMPONENTS') or ls.startswith('END NETS'):
            sec = None; continue
        if ls.startswith('- '):
            buf = [ls]
        else:
            buf.append(ls)
        if ls.endswith(';'):
            s = ' '.join(buf); buf = []
            (flush_comp if sec == 'C' else flush_net)(s[:-1])
fo.close()
