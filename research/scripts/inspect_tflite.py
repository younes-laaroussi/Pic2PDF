import sys, collections, tflite, mmap
path=sys.argv[1]
with open(path,'rb') as f: buf=mmap.mmap(f.fileno(),0,access=mmap.ACCESS_READ)
m=tflite.Model.GetRootAsModel(buf,0)
TT={v:k for k,v in vars(tflite.TensorType).items() if not k.startswith('_')}
BO={v:k for k,v in vars(tflite.BuiltinOperator).items() if not k.startswith('_')}
print("file:",path.split('/')[-1],"subgraphs:",m.SubgraphsLength(),"buffers:",m.BuffersLength())
opcodes=[m.OperatorCodes(i) for i in range(m.OperatorCodesLength())]
def opname(oc):
    b=oc.BuiltinCode() if oc.BuiltinCode() else oc.DeprecatedBuiltinCode()
    n=BO.get(b,str(b))
    if n=='CUSTOM': n='CUSTOM:'+ (oc.CustomCode().decode() if oc.CustomCode() else '?')
    return n
for si in range(m.SubgraphsLength()):
    sg=m.Subgraphs(si)
    name=sg.Name().decode() if sg.Name() else '?'
    ops=collections.Counter(); wtypes=collections.Counter(); wbytes=collections.Counter()
    ins=[sg.Inputs(i) for i in range(sg.InputsLength())]
    for oi in range(sg.OperatorsLength()):
        op=sg.Operators(oi); n=opname(opcodes[op.OpcodeIndex()]); ops[n]+=1
        if n in ('FULLY_CONNECTED','BATCH_MATMUL','CONV_2D','DEPTHWISE_CONV_2D'):
            for k in range(1,op.InputsLength()):
                ti=op.Inputs(k)
                if ti<0: continue
                t=sg.Tensors(ti); b=m.Buffers(t.Buffer())
                if b.DataLength()>0:
                    q=t.Quantization()
                    scheme=''
                    if q is not None:
                        if q.Details() is not None or q.DetailsType()!=0: scheme='blockwise'
                        elif q.ScaleLength()>1: scheme='per-channel'
                        elif q.ScaleLength()==1: scheme='per-tensor'
                    key=f"{n}:{TT[t.Type()]}:{scheme}"
                    wtypes[key]+=1; wbytes[key]+=b.DataLength()
    print(f"\n[{si}] {name}: {sg.OperatorsLength()} ops, {sg.TensorsLength()} tensors, inputs={len(ins)}")
    for k,v in ops.most_common(12): print(f"    {v:5d}  {k}")
    for k in sorted(wtypes): print(f"    weights {k:45s} n={wtypes[k]:4d} bytes={wbytes[k]:,}")
    if si>=3: break
