#!/usr/bin/env python3
"""Aggregate Instruments time-profile XML: leaf-frame self-weight, plus kernel-family buckets.
Frames are deduplicated by 'ref' ids in the xctrace export, so resolve them."""
import sys, re, collections
import xml.etree.ElementTree as ET
path = sys.argv[1]
tree = ET.parse(path); root = tree.getroot()
frames = {}   # id -> name
bts = {}      # backtrace id -> list of frame names (leaf first)
weights = {}
leaf = collections.Counter(); anyframe = collections.Counter(); total = 0
fam = collections.Counter()
def frame_name(f):
    if 'ref' in f.attrib: return frames.get(f.attrib['ref'], '?')
    frames[f.attrib['id']] = f.attrib.get('name', '?'); return frames[f.attrib['id']]
for row in root.iter('row'):
    w = row.find('weight')
    if w is not None:
        if 'ref' in w.attrib: wt = weights.get(w.attrib['ref'], 1000000)
        else: wt = int(w.text); weights[w.attrib['id']] = wt
    else: wt = 1000000
    bt = row.find('tagged-backtrace')
    if bt is None:
        # sentinel rows repeat previous sample; skip
        continue
    if 'ref' in bt.attrib: names = bts.get(bt.attrib['ref'], [])
    else:
        names = [frame_name(f) for f in bt.findall('frame')]
        bts[bt.attrib['id']] = names
    if not names: continue
    total += wt
    leaf[names[0]] += wt
    for n in set(names): anyframe[n] += wt
    s = ' '.join(names).lower()
    key = 'other'
    if 'sme2' in s: key = 'sme2'
    elif 'i8mm' in s or 'mmla' in s: key = 'i8mm'
    elif 'dotprod' in s or 'neondot' in s or '_dot' in s: key = 'dotprod'
    elif 'neon' in s or 'kai_' in s or 'xnn_' in s: key = 'neon/xnn-other'
    fam[key] += wt
ms = lambda x: x/1e6
print(f"total sampled: {ms(total):.0f} ms")
print("\n== kernel-family buckets (sample contains frame matching) ==")
for k,v in fam.most_common(): print(f"  {k:18s} {ms(v):9.0f} ms  {100*v/total:5.1f}%")
print("\n== top 40 leaf (self) frames ==")
for n,v in leaf.most_common(40): print(f"  {ms(v):9.0f} ms {100*v/total:5.1f}%  {n[:120]}")
print("\n== SME2 / KleidiAI / XNN ukernel frames (self weight) ==")
for n,v in leaf.most_common():
    if re.search(r'sme2|kai_|ukernel', n): print(f"  {ms(v):9.0f} ms {100*v/total:5.1f}%  {n[:140]}")
