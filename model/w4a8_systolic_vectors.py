"""Extend preserved W4A8 vectors with full-8x8 and 8x8-tail workloads."""
import json,random,sys
from pathlib import Path
sys.dont_write_bytecode=True
from w4a8_reference import make_case
ROOT=Path(__file__).resolve().parents[1]
def main():
    out=ROOT/'build/w4a8_systolic_vectors';out.mkdir(parents=True,exist_ok=True)
    for group in (32,12):
        base=json.loads((ROOT/f'build/w4a8_vectors/group{group}.json').read_text(encoding='utf8'))
        rng=random.Random(20261012+group)
        extra=[('prefill8',8,16,96,'float'),('decode17',1,17,96,'float'),('tails8',9,11,67,'float')]
        cases=base['cases']+[make_case(rng,*spec[:4],group,spec[4]) for spec in extra]
        tokens=[len(cases)]
        for cid,c in enumerate(cases):
            tokens += [cid,c['m'],c['n'],c['k'],c['groups']]
            tokens += [v for row in c['a'] for v in row]+c['packed']
            tokens += [v for row in c['sx'] for v in row]+[v for row in c['sw'] for v in row]
            tokens += c['output']+[v for row in c['psum'] for g in row for v in g]
        (out/f'group{group}.txt').write_text('\n'.join(map(str,tokens))+'\n',encoding='ascii')
        (out/f'group{group}.json').write_text(json.dumps(dict(seed=20261012,extra_seed=20261012+group,group_size=group,cases=cases),indent=2)+'\n',encoding='utf8')
        assert cases[:12]==base['cases']
        print(f'SYSTOLIC_MODEL_PASS group={group} cases={len(cases)} outputs={sum(c["m"]*c["n"] for c in cases)}')
if __name__=='__main__':main()
