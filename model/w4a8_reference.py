"""Bit-exact W4A8 grouped linear reference and three-level numerical comparison."""
import argparse
import json
import math
import random
from pathlib import Path


def wrap32(v):
    return ((v+(1<<31))%(1<<32))-(1<<31)


def nearest(v):
    return math.floor(v+0.5) if v>=0 else -math.floor(-v+0.5)


def output_round(raw):
    mag=(abs(raw)+128)>>8
    value=mag if raw>=0 else -mag
    return max(-(1<<31),min((1<<31)-1,value))


def reference(qx,qw,sx,sw,group):
    m,k=len(qx),len(qx[0]);n=len(qw[0]);groups=(k+group-1)//group
    psum=[[[0 for _ in range(n)] for _ in range(groups)] for _ in range(m)]
    output=[];raws=[]
    for r in range(m):
        for c in range(n):
            raw=0
            for g in range(groups):
                p=0
                for q in range(g*group,min(k,(g+1)*group)):
                    p=wrap32(p+qx[r][q]*qw[q][c])
                psum[r][g][c]=p
                scaled=p*sx[r][g]*sw[g][c]
                assert -(1<<63)<=scaled<(1<<63)
                raw+=scaled
                assert -(1<<63)<=raw<(1<<63)
            raws.append(raw);output.append(output_round(raw))
    return output,psum,raws


def traffic(m,n,k,rows,cols,tile,group):
    weights=activations=scales=tiles=0
    for mt in range(0,m,rows):
        ml=min(rows,m-mt)
        for nt in range(0,n,cols):
            nl=min(cols,n-nt);q=0
            while q<k:
                length=min(tile,k-q,group-q%group)
                weights+=nl*((q%2+length+1)//2)
                activations+=ml*length
                scales+=2*(ml+nl)
                tiles+=1;q+=length
    return {'weight_bytes':weights,'activation_bytes':activations,'scale_bytes':scales,
            'valid_macs':m*n*k,'compute_cycles':((m+rows-1)//rows)*((n+cols-1)//cols)*k,'tiles':tiles}


def error_metrics(actual,expected):
    errors=[a-b for a,b in zip(actual,expected)]
    return {'max_abs':max(map(abs,errors),default=0.0),
            'rmse':math.sqrt(sum(e*e for e in errors)/len(errors)),
            'relative_l2':math.sqrt(sum(e*e for e in errors)/max(sum(v*v for v in expected),1e-30))}


def make_case(rng,name,m,n,k,group,kind):
    groups=(k+group-1)//group
    if kind=='float':
        x=[[rng.uniform(-2.8,2.8)*(1+q//group) for q in range(k)] for _ in range(m)]
        w=[[rng.uniform(-0.8,0.8)/(1+q//group) for _ in range(n)] for q in range(k)]
        sx_f=[[max(abs(x[r][q]) for q in range(g*group,min(k,(g+1)*group)))/127 or 1/4096 for g in range(groups)] for r in range(m)]
        sw_f=[[max(abs(w[q][c]) for q in range(g*group,min(k,(g+1)*group)))/7 or 1/4096 for c in range(n)] for g in range(groups)]
        a=[[max(-128,min(127,nearest(x[r][q]/sx_f[r][q//group]))) for q in range(k)] for r in range(m)]
        b=[[max(-8,min(7,nearest(w[q][c]/sw_f[q//group][c]))) for c in range(n)] for q in range(k)]
        sx=[[max(1,min(65535,nearest(v*4096))) for v in row] for row in sx_f]
        sw=[[max(1,min(65535,nearest(v*4096))) for v in row] for row in sw_f]
    else:
        a=[[[-128,127,0,-1,1,55,-73][(r*3+q)%7] for q in range(k)] for r in range(m)]
        b=[[((q*3+c*5)%16)-8 for c in range(n)] for q in range(k)]
        sx=[[([128,4096,17001,33][g%4]+r*17)%65536 for g in range(groups)] for r in range(m)]
        sw=[[([7000,51,32001,511][g%4]+c*31)%65536 for c in range(n)] for g in range(groups)]
        if kind=='zero':a=[[0]*k for _ in range(m)]
        if kind in ('tie_pos','tie_neg'):
            a=[[1 if kind=='tie_pos' else -1]];b=[[1]];sx=[[1]];sw=[[128]]
        if kind in ('sat_pos','sat_neg'):
            a=[[-128 if kind=='sat_pos' else 127]*k];b=[[-8] for _ in range(k)]
            sx=[[65535]*groups];sw=[[65535] for _ in range(groups)]
        sx_f=[[v/4096 for v in row] for row in sx];sw_f=[[v/4096 for v in row] for row in sw]
        x=[[a[r][q]*sx_f[r][q//group] for q in range(k)] for r in range(m)]
        w=[[b[q][c]*sw_f[q//group][c] for c in range(n)] for q in range(k)]
    output,psum,raw=reference(a,b,sx,sw,group)
    quant=[];original=[]
    for r in range(m):
        for c in range(n):
            quant.append(sum(psum[r][g][c]*sx_f[r][g]*sw_f[g][c] for g in range(groups)))
            original.append(sum(x[r][q]*w[q][c] for q in range(k)))
    packed=[]
    for c in range(n):
        for q in range(0,k,2):
            lo=b[q][c]&15;hi=(b[q+1][c]&15) if q+1<k else 7
            packed.append(lo|(hi<<4))
    return {'name':name,'kind':kind,'m':m,'n':n,'k':k,'groups':groups,'a':a,'b':b,'packed':packed,
            'sx':sx,'sw':sw,'output':output,'psum':psum,'raw':raw,
            'float_quant':quant,'float_original':original,
            'saturated_outputs':sum(v<-(1<<31) or v>(1<<31)-1 for v in [(abs(t)+128)>>8 if t>=0 else -((abs(t)+128)>>8) for t in raw]),
            'B_fixed_vs_float_quant':error_metrics([v/65536 for v in output],quant),
            'C_quant_vs_original':error_metrics(quant,original)}


def main():
    p=argparse.ArgumentParser();p.add_argument('--out',type=Path,default=Path('build/w4a8_vectors'))
    args=p.parse_args();args.out.mkdir(parents=True,exist_ok=True)
    assert output_round(128)==1 and output_round(-128)==-1
    assert output_round(127)==0 and output_round(-127)==0
    assert output_round(1<<62)==(1<<31)-1 and output_round(-(1<<62))==-(1<<31)
    for group in (32,12):
        rng=random.Random(20261012)
        specs=[('zero',3,5,19,'zero'),('bounds',2,4,41,'direct'),
               ('different_scales',1,4,73,'direct'),('all_tails',5,7,37,'float'),
               ('decode',1,13,96,'float'),('prefill',4,12,96,'float'),
               ('tie_positive',1,1,1,'tie_pos'),('tie_negative',1,1,1,'tie_neg'),
               ('sat_positive',1,1,40,'sat_pos'),('sat_negative',1,1,40,'sat_neg'),
               ('random_rect',3,9,65,'float'),('consecutive_zero',5,7,37,'zero')]
        cases=[make_case(rng,*spec[:4],group,spec[4]) for spec in specs]
        tokens=[len(cases)]
        for cid,c in enumerate(cases):
            tokens += [cid,c['m'],c['n'],c['k'],c['groups']]
            tokens += [v for row in c['a'] for v in row]
            tokens += c['packed']
            tokens += [v for row in c['sx'] for v in row]+[v for row in c['sw'] for v in row]
            tokens += c['output']
            tokens += [v for row in c['psum'] for g in row for v in g]
        (args.out/f'group{group}.txt').write_text('\n'.join(map(str,tokens))+'\n',encoding='ascii')
        (args.out/f'group{group}.json').write_text(json.dumps({'seed':20261012,'group_size':group,'cases':cases},indent=2)+'\n',encoding='utf8')
        print(f'W4A8_MODEL_PASS group={group} cases={len(cases)} outputs={sum(c["m"]*c["n"] for c in cases)}')


if __name__=='__main__':main()
