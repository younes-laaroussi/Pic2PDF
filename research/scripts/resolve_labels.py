#!/usr/bin/env python3
"""Resolve assembly-local labels (e.g. .Linner_loop) in an xctrace time-profile export to
their enclosing global symbol using the app binary's symbol table."""
import sys, re, bisect, subprocess, collections
import xml.etree.ElementTree as ET
xml_path, binary = sys.argv[1], sys.argv[2]
# symbol table of the app binary (unslid addresses)
syms = []
for line in subprocess.run(['nm','-n',binary],capture_output=True,text=True).stdout.splitlines():
    p = line.split()
    if len(p)==3 and p[1] in "tT" and not p[2].startswith((".L","L")):
        syms.append((int(p[0],16), p[2]))
syms.sort(); addrs=[a for a,_ in syms]
def enclosing(addr):
    i = bisect.bisect_right(addrs, addr)-1
    return syms[i][1] if i>=0 else '?'
root = ET.parse(xml_path).getroot()
frames = {}; bts = {}; weights = {}
load_addr = None
label_hits = collections.Counter(); total=0
target = re.compile(r'^\.L|^L[a-z_]+$|inner_loop')
for row in root.iter('row'):
    w = row.find('weight')
    if w is not None:
        if 'ref' in w.attrib: wt = weights.get(w.attrib['ref'],1000000)
        else: wt=int(w.text); weights[w.attrib['id']]=wt
    else: wt=1000000
    bt = row.find('tagged-backtrace')
    if bt is None: continue
    if 'ref' in bt.attrib: leaf = bts.get(bt.attrib['ref'])
    else:
        fs = bt.findall('frame'); leaf=None
        for k,f in enumerate(fs):
            if 'ref' in f.attrib: info = frames.get(f.attrib['ref'])
            else:
                b = f.find('binary')
                bname = None; la=None
                if b is not None:
                    if 'ref' in b.attrib: bname, la = frames.get('bin'+b.attrib['ref'],(None,None))
                    else:
                        bname=b.attrib.get('name'); la=int(b.attrib.get('load-addr','0'),16); frames['bin'+b.attrib['id']]=(bname,la)
                info=(f.attrib.get('name','?'), int(f.attrib.get('addr','0'),16), bname, la)
                frames[f.attrib['id']]=info
            if k==0: leaf=info
        bts[bt.attrib['id']]=leaf
    if not leaf: continue
    total+=wt
    name, addr, bname, la = leaf
    if bname=='Pic2PDF' and target.search(name):
        # unslide: binary vmaddr base is 0x100000000 for iOS main executables
        unslid = addr - la + 0x100000000
        label_hits[(name, enclosing(unslid))]+=wt
print(f"total {total/1e6:.0f} ms")
for (n,enc),v in label_hits.most_common(20):
    print(f"  {v/1e6:8.0f} ms {100*v/total:5.1f}%  {n:16s} -> {enc}")
