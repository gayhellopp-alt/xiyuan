"""Independent complete external-memory FFN oracle, including every intermediate."""
import argparse,json,random,sys
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
sys.path[:0]=[str(ROOT/'model'),str(ROOT/'model/vector')]
from w4a8_reference import reference
from ffn_reference import element
from dynamic_reference import dynamic

def generate(out):
    out.mkdir(parents=True,exist_ok=True)
    records=[]
    for group in (32,12):
        for case,(m,k,h,n) in enumerate(((1,19,37,5),(3,35,29,7),(2,13,25,3))):
            rng=random.Random(3300+group+case)
            a=[[rng.randint(-16,16) for _ in range(k)] for _ in range(m)]
            if case==2:a=[[0]*k for _ in range(m)]
            wg=[[rng.randint(-8,7) for _ in range(h)] for _ in range(k)]
            wu=[[rng.randint(-8,7) for _ in range(h)] for _ in range(k)]
            ng=(k+group-1)//group;nh=(h+group-1)//group
            sx=[[rng.choice((256,512,900)) for _ in range(ng)] for _ in range(m)]
            sg=[[rng.randint(200,1000) for _ in range(h)] for _ in range(ng)]
            su=[[rng.randint(300,1100) for _ in range(h)] for _ in range(ng)]
            gate,_,_=reference(a,wg,sx,sg,group);up,_,_=reference(a,wu,sx,su,group)
            q=[];sc=[]
            for r in range(m):
                row=[element(gate[r*h+i],up[r*h+i])['product'] for i in range(h)]
                for g in range(nh):
                    result=dynamic(row[g*group:min(h,(g+1)*group)])
                    q+=result['q'];sc.append(result['scale'])
            wd=[[rng.randint(-8,7) for _ in range(n)] for _ in range(h)]
            sd=[[rng.randint(200,1000) for _ in range(n)] for _ in range(nh)]
            y,_,_=reference([q[r*h:(r+1)*h] for r in range(m)],wd,[sc[r*nh:(r+1)*nh] for r in range(m)],sd,group)
            image=bytearray([0xcd]*65536);expected=image.copy();linear_expected=image.copy()
            rp=bytearray(65536);wp=bytearray(65536)
            # All allocated buffers and padding are disjoint; A/sx are shared read-only.
            bases=[1021,3001,7000,9000,15000,20001,24000,30000,34003,38000,42001,46000,50000]
            aa,wg_b,sx_b,sg_b,yg,wu_b,su_b,yu,aq,sq,wd_b,sd_b,yy=bases
            def put(buf,base,stride,rows,width,values,perm,unit=1):
                it=iter(values)
                for r in range(rows):
                    for c in range(width):
                        addr=base+r*stride+c*unit
                        raw=(next(it)&((1<<(unit*8))-1)).to_bytes(unit,'little')
                        buf[addr:addr+unit]=raw;perm[addr:addr+unit]=b'\x01'*unit
            def flat(v):return [x for row in v for x in row]
            def packed(w):
                return [((w[j][c]&15)|(((w[j+1][c]&15) if j+1<len(w) else 0)<<4)) for c in range(len(w[0])) for j in range(0,len(w),2)]
            astr=k+7;wstr=(k+1)//2+5;sxstr=2*ng+6;swstr=2*h+8;ystr=4*h+12
            aqstr=h+7;sqstr=2*nh+6;wdstr=(h+1)//2+5;sdstr=2*n+8;yystr=4*n+12
            put(image,aa,astr,m,k,flat(a),rp);put(image,wg_b,wstr,h,(k+1)//2,packed(wg),rp)
            put(image,sx_b,sxstr,m,ng,flat(sx),rp,2);put(image,sg_b,swstr,ng,h,flat(sg),rp,2)
            put(image,wu_b,wstr,h,(k+1)//2,packed(wu),rp);put(image,su_b,swstr,ng,h,flat(su),rp,2)
            put(image,wd_b,wdstr,n,(h+1)//2,packed(wd),rp);put(image,sd_b,sdstr,nh,n,flat(sd),rp,2)
            expected=image.copy();linear_expected=image.copy()
            put(expected,yg,ystr,m,h,gate,wp,4);put(linear_expected,yg,ystr,m,h,gate,bytearray(65536),4)
            put(expected,yu,ystr,m,h,up,wp,4)
            put(expected,aq,aqstr,m,h,q,wp);put(expected,sq,sqstr,m,nh,sc,wp,2)
            put(expected,yy,yystr,m,n,y,wp,4)
            # Intermediates become readable only in later stages; permission is static,
            # while stage/fence sequencing is checked independently by the testbench.
            for base,stride,rows,width,unit in ((yg,ystr,m,h,4),(yu,ystr,m,h,4),(aq,aqstr,m,h,1),(sq,sqstr,m,nh,2)):
                for r in range(rows):
                    for c in range(width*unit):rp[base+r*stride+c]=1
            def extent(rows,stride,width):return (rows-1)*stride+width
            gate_task=[501,m,h,k,aa,wg_b,sx_b,sg_b,yg,astr,wstr,sxstr,swstr,ystr,
                extent(m,astr,k),extent(h,wstr,(k+1)//2),extent(m,sxstr,2*ng),extent(ng,swstr,2*h),extent(m,ystr,4*h)]
            up_task=gate_task.copy();up_task[0]=502;up_task[5]=wu_b;up_task[7]=su_b;up_task[8]=yu
            down_task=[503,m,n,h,aq,wd_b,sq,sd_b,yy,aqstr,wdstr,sqstr,sdstr,yystr,
                extent(m,aqstr,h),extent(n,wdstr,(h+1)//2),extent(m,sqstr,2*nh),extent(nh,sdstr,2*n),extent(m,yystr,4*n)]
            stem=f'g{group}_case{case}'
            tokens=[700+case,group]+gate_task+up_task+down_task
            (out/f'{stem}.txt').write_text('\n'.join(map(str,tokens))+'\n',encoding='ascii')
            for suffix,data in [('input',image),('expected',expected),('linear',linear_expected),('read',rp),('write',wp)]:
                (out/f'{stem}.{suffix}.hex').write_text(''.join(f'{b:02x}\n' for b in data),encoding='ascii')
            records.append(dict(group=group,case=case,m=m,k=k,h=h,n=n,quant_bytes=m*h,scale_bytes=2*m*nh))
    (out/'manifest.json').write_text(json.dumps(records,indent=2)+'\n',encoding='utf-8')
    print('SYSTEM_REFERENCE_PASS cases=6')

if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('--out',type=Path,required=True);generate(p.parse_args().out)
