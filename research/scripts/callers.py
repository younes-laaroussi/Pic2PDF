import sys, re, collections
import xml.etree.ElementTree as ET
xml_path = sys.argv[1]; pats = [re.compile(p) for p in sys.argv[2:]]
root = ET.parse(xml_path).getroot()
frames={}; bts={}; weights={}
res = {p.pattern: collections.Counter() for p in pats}
for row in root.iter('row'):
    w=row.find('weight')
    if w is not None:
        if 'ref' in w.attrib: wt=weights.get(w.attrib['ref'],1000000)
        else: wt=int(w.text); weights[w.attrib['id']]=wt
    else: wt=1000000
    bt=row.find('tagged-backtrace')
    if bt is None: continue
    if 'ref' in bt.attrib: names=bts.get(bt.attrib['ref'],[])
    else:
        names=[]
        for f in bt.findall('frame'):
            if 'ref' in f.attrib: names.append(frames.get(f.attrib['ref'],'?'))
            else: frames[f.attrib['id']]=f.attrib.get('name','?'); names.append(frames[f.attrib['id']])
        bts[bt.attrib['id']]=names
    if not names: continue
    for p in pats:
        if p.search(names[0]):
            # pick informative ancestor frames: first matching 'odml|tflite::|Vision|vision|Prefill|Decode|Llm|llm|Encoder|Session|Graph|Calculator'
            anc=[n for n in names[1:] if re.search(r'odml|Vision|vision|Prefill|Decode|prefill|decode|Llm|LLM|Encoder|Calculator|Session|Init|xnn_create|xnn_reshape|xnn_setup|Subgraph|Interpreter|Invoke|ml_drift|GraphRunner|Executor', n)]
            key=' <- '.join(a[:70] for a in anc[:6])
            res[p.pattern][key]+=wt
for p,c in res.items():
    print(f"\n### leaf matches /{p}/")
    tot=sum(c.values())
    for k,v in c.most_common(6): print(f"  {v/1e6:8.0f} ms {100*v/tot:5.1f}%  {k}")
