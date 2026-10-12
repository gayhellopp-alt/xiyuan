"""Independent integer references for ordered jobs using immutable resident matrices."""
import argparse
import json
import random
from pathlib import Path


def wrap32(x):
    return ((x + (1 << 31)) % (1 << 32)) - (1 << 31)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--out', type=Path, default=Path('build/npu_vectors'))
    args = parser.parse_args()
    args.out.mkdir(parents=True, exist_ok=True)
    rng = random.Random(20261012)
    # Includes FIFO wrap, tails, GEMV, rejected dimensions/opcodes and duplicate tags.
    jobs = [(1,101,4,4,8),(1,102,7,9,13),(1,103,1,9,17),
            (1,104,16,16,32),(1,105,3,7,6),(1,106,0,4,8),
            (9,107,4,4,8),(1,108,17,4,8),(1,109,4,4,33),
            (1,110,2,5,7),(1,110,1,1,1),(1,112,5,3,11)]
    tokens = [3]
    manifest = {'seed':20261012,'capacity':{'M':16,'N':16,'K':32},'groups':[],
                'overflow':'signed INT32 wrap modulo 2^32 after each MAC'}
    for group in range(3):
        if group == 0:
            a = [[0]*32 for _ in range(16)]
            b = [[rng.randint(-128,127) for _ in range(16)] for _ in range(32)]
        elif group == 1:
            edge = [-128,127,-1,0,1]
            a = [[edge[(r*3+k)%5] for k in range(32)] for r in range(16)]
            b = [[edge[(k*2+c*3)%5] for c in range(16)] for k in range(32)]
        else:
            a = [[rng.randint(-128,127) for _ in range(32)] for _ in range(16)]
            b = [[rng.randint(-128,127) for _ in range(16)] for _ in range(32)]
        tokens += [group, len(jobs)]
        tokens += [v for row in a for v in row] + [v for row in b for v in row]
        records=[]
        for op,tag,m,n,k in jobs:
            status = 2 if op != 1 else (1 if not(1<=m<=16 and 1<=n<=16 and 1<=k<=32) else 0)
            tokens += [op,tag,m,n,k,status]
            output=[]
            if status == 0:
                for r in range(m):
                    for c in range(n):
                        acc=0
                        for q in range(k):
                            acc=wrap32(acc+a[r][q]*b[q][c])
                        output.append(acc)
                tokens += output
            records.append({'opcode':op,'tag':tag,'M':m,'N':n,'K':k,'status':status,'outputs':len(output)})
        manifest['groups'].append({'group':group,'jobs':records})
    (args.out/'vectors.txt').write_text('\n'.join(map(str,tokens))+'\n',encoding='ascii')
    (args.out/'manifest.json').write_text(json.dumps(manifest,indent=2)+'\n',encoding='utf8')
    print('NPU_REFERENCE_PASS groups=3 descriptors=36 successful_jobs=24 outputs=' + str(sum(j['outputs'] for g in manifest['groups'] for j in g['jobs'])))


if __name__ == '__main__':
    main()
