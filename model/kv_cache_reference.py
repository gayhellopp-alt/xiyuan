"""Storage oracle only: no Attention or quantization computation."""
import argparse
import json
from pathlib import Path


def config():
    return dict(layers=2,heads=2,capacity=4,dimension=5,group_size=4,
                base=[4093,10001,16000,20000],token_stride=[8,10,6,8],
                head_stride=[40,50,32,40],layer_stride=[96,112,80,96],bytes=[165,197,134,164])


def width(c,p):
    return c['dimension'] if p<2 else 2*((c['dimension']+c['group_size']-1)//c['group_size'])


def address(c,p,l,h,t,b):
    assert 0<=p<4 and 0<=l<c['layers'] and 0<=h<c['heads']
    assert 0<=t<c['capacity'] and 0<=b<width(c,p)
    a=c['base'][p]+l*c['layer_stride'][p]+h*c['head_stride'][p]+t*c['token_stride'][p]+b
    assert c['base'][p]<=a<c['base'][p]+c['bytes'][p] and a<2**32
    return a


def value(c,p,l,h,t,b):
    if p<2:
        return ((-128+p*53+l*31+h*19+t*17+b*7)&255)
    # Per token/head/dimension-group UQ4.12, LE, includes zero and high unsigned codes.
    scale=([0,65535,4096,17001][(l+h+t+b//2)%4]+(p-2)*29)&65535
    return (scale>>((b%2)*8))&255


def generate(out):
    out.mkdir(parents=True,exist_ok=True);c=config();tokens=[]
    for l in range(c['layers']):
        for h in range(c['heads']):
            for t in range(c['capacity']):
                for p in range(4):
                    for b in range(width(c,p)):
                        tokens.extend([address(c,p,l,h,t,b),value(c,p,l,h,t,b)])
    assert len(set(tokens[::2]))==len(tokens)//2
    (out/'kv_vectors.txt').write_text('\n'.join(map(str,tokens))+'\n',encoding='ascii')
    (out/'kv_config.json').write_text(json.dumps(c,indent=2)+'\n')
    print(f'KV_STORAGE_REFERENCE_PASS bytes={len(tokens)//2}')


if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('--out',type=Path,default=Path('build/kv_vectors'))
    generate(p.parse_args().out)
