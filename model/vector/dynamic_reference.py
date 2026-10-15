"""Dynamic UQ4.12 group quantization and two-layer integer/float references."""
import argparse
import json
import random
import sys
from pathlib import Path
sys.dont_write_bytecode=True
from requant_reference import requant, MIN32, MAX32
sys.path.insert(0,str(Path(__file__).resolve().parents[1]))
from w4a8_reference import reference, error_metrics


def dynamic(values):
    assert values and all(MIN32<=t<=MAX32 for t in values)
    a=max(abs(t) for t in values)
    dividend,quotient,remainder=a,0,0
    for _ in range(32):
        trial=(remainder<<1)|(dividend>>31)
        bit=int(trial>=2032)
        remainder=trial-bit*2032
        dividend=(dividend<<1)&0xffffffff
        quotient=(quotient<<1)|bit
        assert 0<=remainder<2032
    assert (quotient,remainder)==divmod(a,2032)
    candidate=quotient+int(remainder!=0)
    assert candidate==(a+2031)//2032
    scale=max(1,min(65535,candidate))
    results=[requant(t,scale) for t in values]
    if candidate<=65535:
        assert all(-127<=r['q']<=127 and not r['saturated'] for r in results)
    return dict(absmax=a,scale=scale,scale_clipped=int(candidate>65535),
                q=[r['q'] for r in results],sat=[r['saturated'] for r in results])


def module_cases(g):
    rng=random.Random(20261014+g)
    vals=[0,1,-1,8,-8,2031,-2031,2032,-2032,2033,-2033,
          2032*65535-1,2032*65535,2032*65535+1,MIN32,MAX32]
    cases=[]
    def add(values):
        cases.append(dict(row=len(cases),group=2,k=2*g+len(values),length=len(values),values=values,**dynamic(values)))
    for v in vals:add([v])
    add([0]*g)
    add([MIN32,MAX32]+[0]*(g-2))
    for length in range(1,g+1):
        add([rng.randint(-1000000,1000000) for _ in range(length)])
    for _ in range(80):
        length=rng.randint(1,g)
        add([rng.randint(MIN32,MAX32) for _ in range(length)])
    # Exact half values after absmax selects scale=2.
    add([4064,16,-16,15,-15,17,-17]+[0]*(g-7))
    return cases


def packed(w):
    k,n=len(w),len(w[0])
    return [(w[q][c]&15)|((w[q+1][c]&15)<<4 if q+1<k else 0) for c in range(n) for q in range(0,k,2)]


def flatten(a):
    return [v for row in a for v in row]


def chain_cases(g):
    g1=12 if g==32 else 32
    rng=random.Random(20261014+g)
    cases=[]
    for cid,(m,k,h,n,kind) in enumerate([(1,19,37,5,'random'),(3,35,29,7,'random'),
            (5,23,61,6,'random'),(2,13,25,3,'zero'),(1,9,33,4,'clipped')]):
        ng1=(k+g1-1)//g1;ng2=(h+g-1)//g
        a=[[rng.randint(-30,30) for _ in range(k)] for _ in range(m)]
        w1=[[rng.randint(-8,7) for _ in range(h)] for _ in range(k)]
        sx1=[[rng.choice([2048,4096,6800]) for _ in range(ng1)] for _ in range(m)]
        sw1=[[rng.choice([700,1700,2100]) for _ in range(h)] for _ in range(ng1)]
        if kind=='zero':a=[[0]*k for _ in range(m)]
        if kind=='clipped':
            a=[[127]*k for _ in range(m)];w1=[[7 if c%2==0 else -8 for c in range(h)] for _ in range(k)]
            sx1=[[65535]*ng1 for _ in range(m)];sw1=[[65535]*h for _ in range(ng1)]
        y1,p1,raw1=reference(a,w1,sx1,sw1,g1)
        q2=[[0]*h for _ in range(m)];s2=[[0]*ng2 for _ in range(m)];clips=[];sats=[];absmax=[]
        for r in range(m):
            for group in range(ng2):
                start=group*g;d=dynamic(y1[r*h+start:r*h+min(h,start+g)])
                q2[r][start:start+len(d['q'])]=d['q'];s2[r][group]=d['scale']
                clips.append(d['scale_clipped']);sats+=d['sat'];absmax.append(d['absmax'])
        w2=[[rng.randint(-8,7) for _ in range(n)] for _ in range(h)]
        sw2=[[rng.choice([301,911,2500])+group*7+c for c in range(n)] for group in range(ng2)]
        y2,p2,raw2=reference(q2,w2,s2,sw2,g)
        dequant=flatten([[q2[r][q]*s2[r][q//g]/4096 for q in range(h)] for r in range(m)])
        ideal1=[t/(1<<24) for t in raw1]
        ideal2=[sum(ideal1[r*h+q]*w2[q][c]*sw2[q//g][c]/4096 for q in range(h)) for r in range(m) for c in range(n)]
        quant2=[t/(1<<24) for t in raw2]
        cases.append(dict(id=cid,kind=kind,m=m,k=k,h=h,n=n,g1=g1,g2=g,ng1=ng1,ng2=ng2,
            a=flatten(a),w1=packed(w1),sx1=flatten(sx1),sw1=flatten(sw1),y1=y1,p1=[v for row in p1 for group in row for v in group],
            q2=flatten(q2),s2=flatten(s2),clips=clips,sats=sats,absmax=absmax,w2=packed(w2),sw2=flatten(sw2),
            y2=y2,p2=[v for row in p2 for group in row for v in group],
            errors=dict(layer1_fixed_vs_float=error_metrics([t/65536 for t in y1],ideal1),
                        requant_vs_layer1=error_metrics(dequant,[t/65536 for t in y1]),
                        layer2_fixed_vs_float_quant=error_metrics([t/65536 for t in y2],quant2),
                        final_vs_float_chain=error_metrics([t/65536 for t in y2],ideal2))))
    return cases


def main():
    p=argparse.ArgumentParser();p.add_argument('--out',type=Path,default=Path('build/dynamic_vectors'));args=p.parse_args()
    args.out.mkdir(parents=True,exist_ok=True)
    # Every encoding transition, maximum abs value and range-clipping boundary.
    checks=0
    for s in range(1,65536):
        for a in (2032*s-1,2032*s,2032*s+1):
            d=dynamic([a,-a]);assert d['scale']==max(1,min(65535,(a+2031)//2032));checks+=1
    metadata=dict(scale_transition_checks=checks,seed=20261014,groups={})
    for g in (32,12):
        cases=module_cases(g);tokens=[len(cases)]
        for c in cases:
            tokens += [c[k] for k in ('row','group','k','length','scale','scale_clipped','absmax')]
            for t,q,s in zip(c['values'],c['q'],c['sat']):tokens += [t,q,s]
        (args.out/f'group{g}.txt').write_text('\n'.join(map(str,tokens))+'\n',encoding='ascii')
        (args.out/f'group{g}.json').write_text(json.dumps(cases,indent=2)+'\n',encoding='utf8')
        chain=chain_cases(g);tokens=[len(chain)]
        for c in chain:
            tokens += [c[k] for k in ('id','m','k','h','n','ng1','ng2')]
            for k in ('a','w1','sx1','sw1','y1','p1','q2','s2','clips','sats','absmax','w2','sw2','y2','p2'):tokens+=c[k]
        (args.out/f'chain{g}.txt').write_text('\n'.join(map(str,tokens))+'\n',encoding='ascii')
        (args.out/f'chain{g}.json').write_text(json.dumps(chain,indent=2)+'\n',encoding='utf8')
        metadata['groups'][str(g)]=dict(cases=len(cases),elements=sum(c['length'] for c in cases),
            clipped=sum(c['scale_clipped'] for c in cases),saturated=sum(sum(c['sat']) for c in cases),chain_cases=len(chain))
    (args.out/'reference_checks.json').write_text(json.dumps(metadata,indent=2)+'\n',encoding='utf8')
    print('DYNAMIC_MODEL_PASS',json.dumps(metadata))


if __name__=='__main__':main()
