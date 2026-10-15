"""Bit-exact bounded attention plus an independent floating-point comparison."""
import argparse,json,math,random
from pathlib import Path

def round_wide(v,shift):
    a=(abs(v)+(1<<(shift-1)))>>shift
    return -a if v<0 else a

def rounded(v,shift):
    return max(-(1<<31),min((1<<31)-1,round_wide(v,shift)))

def attention(q,qs,k,ks,v,vs,group,gain):
    scores=[]
    for token,row in enumerate(k):
        total=sum(sum(q[i]*row[i] for i in range(g*group,min(len(q),(g+1)*group)))*qs[g]*ks[token][g]
                  for g in range(len(qs)))
        scores.append(round_wide(round_wide(total,8)*gain,12))
    mx=max(scores)
    e=[math.floor(math.exp(-min(256,(mx-s+2048)>>12)/16)*65536+.5) for s in scores]
    den=sum(e);prob=[((x<<16)+den//2)//den for x in e]
    y=[rounded(sum(prob[t]*v[t][i]*vs[t][i//group] for t in range(len(k))),12) for i in range(len(q))]
    fs=[sum(q[i]*qs[i//group]/4096*row[i]*ks[t][i//group]/4096 for i in range(len(q)))*gain/4096 for t,row in enumerate(k)]
    fm=max(fs);fe=[math.exp(x-fm) for x in fs];fp=[x/sum(fe) for x in fe]
    fy=[sum(fp[t]*v[t][i]*vs[t][i//group]/4096 for t in range(len(k))) for i in range(len(q))]
    return y,dict(scores=scores,probabilities=prob,max_probability_error=max(abs(a/65536-b) for a,b in zip(prob,fp)),
                   max_output_error=max(abs(a/65536-b) for a,b in zip(y,fy)))

def generate(out):
    out.mkdir(parents=True,exist_ok=True);metadata=[]
    for group in (32,4,3):
        d,capacity,tokens=9,8,7;ng=(d+group-1)//group;rng=random.Random(900+group)
        k=[[rng.randint(-16,16) for _ in range(d)] for _ in range(tokens)]
        v=[[rng.randint(-20,20) for _ in range(d)] for _ in range(tokens)]
        ks=[[rng.choice((600,1200,2500,4096)) for _ in range(ng)] for _ in range(tokens)]
        vs=[[rng.choice((500,1000,2000,4096)) for _ in range(ng)] for _ in range(tokens)]
        bases=[1021,6001,10000,14000];strides=[d+3,d+5,2*ng+4,2*ng+6]
        sizes=[(capacity-1)*s+(d if p<2 else 2*ng) for p,s in enumerate(strides)]
        image=bytearray([0xcd]*65536);perms=bytearray(65536)
        for p in range(4):
            for t in range(capacity):
                for j in range(d if p<2 else 2*ng):perms[bases[p]+t*strides[p]+j]=1
        append=[]
        for t in range(tokens):
            planes=[bytes(x&255 for x in k[t]),bytes(x&255 for x in v[t]),
                    b''.join(x.to_bytes(2,'little') for x in ks[t]),b''.join(x.to_bytes(2,'little') for x in vs[t])]
            append+=list(b''.join(planes))
        headers=[group,d,capacity,tokens,5]+bases+strides+sizes
        query_tokens=[];written_tokens=0;results=[]
        for case,count in enumerate((1,3,7,7,7)):
            q=[rng.randint(-16,16) for _ in range(d)];qs=[rng.choice((700,1500,4096)) for _ in range(ng)]
            if case==3:q=[0]*d
            if case==4:q=[127]*d;qs=[65535]*ng
            gain=round(4096/math.sqrt(d));y,stats=attention(q,qs,k[:count],ks[:count],v[:count],vs[:count],group,gain)
            assert stats['max_probability_error']<0.016,stats
            for t in range(written_tokens,count):
                planes=[bytes(x&255 for x in k[t]),bytes(x&255 for x in v[t]),
                        b''.join(x.to_bytes(2,'little') for x in ks[t]),b''.join(x.to_bytes(2,'little') for x in vs[t])]
                for p,raw in enumerate(planes):image[bases[p]+t*strides[p]:bases[p]+t*strides[p]+len(raw)]=raw
            written_tokens=count
            ybase=18000+case*256
            for i,value in enumerate(y):
                image[ybase+4*i:ybase+4*i+4]=(value&0xffffffff).to_bytes(4,'little');perms[ybase+4*i:ybase+4*i+4]=b'\x01'*4
            (out/f'g{group}_expected{case}.hex').write_text(''.join(f'{x:02x}\n' for x in image),encoding='ascii')
            query_tokens += [900+case,count,d,gain,ybase]+q+[qs[i//group] for i in range(d)]
            results.append(dict(case=case,count=count,**stats))
        (out/f'g{group}_meta.txt').write_text('\n'.join(map(str,headers+query_tokens))+'\n',encoding='ascii')
        (out/f'g{group}_append.txt').write_text('\n'.join(map(str,append))+'\n',encoding='ascii')
        (out/f'g{group}_permissions.hex').write_text(''.join(f'{x:02x}\n' for x in perms),encoding='ascii')
        metadata.append(dict(group=group,dimension=d,capacity=capacity,queries=results))
    (out/'reference.json').write_text(json.dumps(metadata,indent=2)+'\n',encoding='utf-8')
    print('ATTENTION_REFERENCE_PASS groups=3 queries=15 max_probability_error='+str(max(q['max_probability_error'] for m in metadata for q in m['queries'])))

if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('--out',required=True,type=Path);generate(p.parse_args().out)
