"""Independent byte-addressed tensor images and project bit-exact expected Y."""
import argparse
import json
import random
from pathlib import Path
from w4a8_reference import make_case


def generate(out):
    out.mkdir(parents=True, exist_ok=True)
    records=[]
    for group in (32,12):
        for job,(m,n,k) in enumerate(((8,8,37),(9,11,41))):
            c=make_case(random.Random(773+job),f'memory{job}',m,n,k,group,'float')
            g=c['groups'];shift=job*128
            bases=[4093+shift,10001+shift,16000+shift,20000+shift,30004+shift]
            strides=[k+7,(k+1)//2+5,2*g+6,2*n+8,4*n+12]
            sizes=[(m-1)*strides[0]+k,(n-1)*strides[1]+(k+1)//2,
                   (m-1)*strides[2]+2*g,(g-1)*strides[3]+2*n,(m-1)*strides[4]+4*n]
            image=bytearray([0xcd]*65536)
            for r in range(m):
                for q in range(k): image[bases[0]+r*strides[0]+q]=c['a'][r][q]&255
            for col in range(n):
                for p in range((k+1)//2): image[bases[1]+col*strides[1]+p]=c['packed'][col*((k+1)//2)+p]
            for r in range(m):
                for z in range(g):
                    a=bases[2]+r*strides[2]+2*z;image[a:a+2]=c['sx'][r][z].to_bytes(2,'little')
            for z in range(g):
                for col in range(n):
                    a=bases[3]+z*strides[3]+2*col;image[a:a+2]=c['sw'][z][col].to_bytes(2,'little')
            # Task token order is explicit; task_id differs between consecutive jobs.
            tokens=[101+job,m,n,k,1,group]+bases+strides+sizes+c['output']
            stem=f'g{group}_job{job}'
            (out/f'{stem}.txt').write_text('\n'.join(map(str,tokens))+'\n',encoding='ascii')
            (out/f'{stem}.hex').write_text('\n'.join(f'{x:02x}' for x in image)+'\n',encoding='ascii')
            records.append({'stem':stem,'m':m,'n':n,'k':k,'group':group,'bases':bases,'strides':strides,'sizes':sizes})
    (out/'manifest.json').write_text(json.dumps(records,indent=2)+'\n',encoding='utf8')
    print('W4A8_MEMORY_VECTORS_PASS images=4')


if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('--out',type=Path,default=Path('build/w4a8_memory_vectors'))
    generate(p.parse_args().out)
