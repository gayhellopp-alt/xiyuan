"""Independent coordinate/transaction model; numerical golden remains unchanged."""
import argparse
import json
import sys
from pathlib import Path
sys.dont_write_bytecode=True
from w4a8_reference import reference
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'scripts'))
from reuse_traffic import traffic


def slot_plan(m,n,k,rows,cols,tile,group,valid_only=True):
    ng=(k+group-1)//group
    output_slots=save_slots=physical_groups=0
    tiles=[]
    for mt in range(0,m,rows):
        for nt in range(0,n,cols):
            ml=min(rows,m-mt);nl=min(cols,n-nt)
            # Explicit coordinate enumeration, not the DUT's next/last formula.
            slots=[r*cols+c for r in range(rows) for c in range(cols)
                   if not valid_only or (r<ml and c<nl)]
            assert len(slots)==(ml*nl if valid_only else rows*cols)
            output_slots+=len(slots);save_slots+=len(slots)*ng;physical_groups+=ng
            tiles.append(dict(mt=mt,nt=nt,ml=ml,nl=nl,slots=slots))
    packet=traffic(m,n,k,rows,cols,tile,group,8,1,1,1)
    fixed=2*output_slots+save_slots+2*physical_groups+2*packet['tiles']+2*m*n+1
    assert not valid_only or output_slots==m*n and save_slots==m*n*ng
    return dict(init_slots=output_slots,out_req_slots=output_slots,saved_slots=save_slots,
                issued_slots=save_slots,retired_slots=save_slots,physical_groups=physical_groups,
                fixed_cycles=fixed,packet=packet,tiles=tiles)


def main():
    p=argparse.ArgumentParser();p.add_argument('--out',type=Path,default=Path('build/w4a8_valid_vectors'))
    args=p.parse_args();args.out.mkdir(parents=True,exist_ok=True)
    root=Path(__file__).resolve().parents[1];summary=dict(preserved_numerical_golden=True,plans={})
    for g in (32,12):
        cases=json.loads((root/f'build/w4a8_systolic_vectors/group{g}.json').read_text(encoding='utf8'))['cases']
        # Re-evaluate the original arithmetic without changing its data or scale.
        for c in cases:
            output,psum,raw=reference(c['a'],c['b'],c['sx'],c['sw'],g)
            assert output==c['output'] and psum==c['psum'] and raw==c['raw']
        for name,r,cols,tile,valid in [('v4',4,4,8,1),('v8',8,8,8,1),('alt',2,3,5,1),
              ('one',1,1,8,1),('single',4,4,8,1),('words8',8,8,19,1),('base4',4,4,8,0),('base8',8,8,8,0)]:
            if (name=='alt')!=(g==12):continue
            summary['plans'][name]=[slot_plan(c['m'],c['n'],c['k'],r,cols,tile,g,valid) for c in cases]
    (args.out/'slot_plans.json').write_text(json.dumps(summary,indent=2)+'\n',encoding='utf8')
    print('VALID_COORDINATE_MODEL_PASS configs='+str(len(summary['plans'])))


if __name__=='__main__':main()
