"""Audit NPU simulation/SV source identity, integer cycles and actual Vivado reports."""
import argparse
import csv
import hashlib
import json
import re
import sys
from pathlib import Path
sys.dont_write_bytecode = True
from summarize import read, utilization, timing
sys.path.insert(0, str(Path(__file__).resolve().parents[1]/'model'))
from generate_vectors import double_buffer_cycles


def verify_sources(root, work):
    saved=json.loads(read(work/'source_inputs.json'))
    for name,digest in saved['files'].items():
        assert hashlib.sha256((root/name).read_bytes()).hexdigest()==digest, name
    return saved


def main():
    parser=argparse.ArgumentParser()
    parser.add_argument('--root',type=Path,default=Path(__file__).resolve().parents[1])
    args=parser.parse_args()
    root=args.root.resolve()
    manifest=json.loads(read(root/'build/npu_vectors/manifest.json'))
    out={'scope':'NPU ordered resident-buffer GEMM scheduler; evaluation only',
         'seed':manifest['seed'],'simulations':[]}
    expected=[(g['group'],i,j) for g in manifest['groups'] for i,j in enumerate(g['jobs'])]
    for name,rows,cols,tk,depth in [('4x4_k8_q4',4,4,8,4),('2x3_k5_q3',2,3,5,3)]:
        work=root/f'build/sim_npu_{name}'
        verify_sources(root,work)
        assert (work/'vectors.txt').read_bytes()==(root/'build/npu_vectors/vectors.txt').read_bytes()
        log=read(work/'run.log')
        assert read(work/'PASS.txt').strip()=='PASS'
        assert not re.search(r'Fatal:|FAILED|TIMEOUT|ERROR:',log)
        match=re.search(r'NPU_TESTS_PASS rows=(\d+) cols=(\d+) tile_k=(\d+) queue=(\d+) descriptors=(\d+) comparisons=(\d+) checks=(\d+) full_stalls=(\d+) simultaneous=(\d+) reset_jobs=(\d+)',log)
        assert match and tuple(map(int,match.group(1,2,3,4)))==(rows,cols,tk,depth)
        assert int(match[5])==36 and int(match[6])==1191 and int(match[10])==2
        assert int(match[8])>0 and int(match[9])>0
        lines=[s for s in read(work/'results.csv').splitlines() if not s.startswith('#')]
        records=list(csv.DictReader(lines))
        assert len(records)==len(expected)==36
        for record,(group,index,job) in zip(records,expected):
            r={key:int(value) for key,value in record.items()}
            assert (r['group'],r['job'],r['tag'],r['status'],r['m'],r['n'],r['k'])==(
                group,index,job['tag'],job['status'],job['M'],job['N'],job['K'])
            assert r['outputs']==job['outputs']
            active=double_buffer_cycles(r['m'],r['n'],r['k'],rows,cols,tk,0) if r['status']==0 else 0
            assert r['core_active_cycles']==active
            assert r['core_cycles']==active+(3 if index==0 else 0)
        out['simulations'].append({'name':name,'ROWS':rows,'COLS':cols,'TILE_K':tk,'QUEUE_DEPTH':depth,
            'ordered_descriptors':36,'successful_batch_jobs':24,'rejected_batch_jobs':12,
            'post_reset_successful_jobs':2,'comparisons':1191,'checks':int(match[7]),
            'submit_stall_cycles':int(match[8]),'simultaneous_enqueue_dequeue':int(match[9]),
            'source_hashes_match':True,'cycles':records})
    work=root/'build/synth_npu'
    saved=verify_sources(root,work)
    assert saved['top']=='npu_top' and saved['QUEUE_DEPTH']==4
    log=read(work/'synth_npu.log')
    assert re.search(r'^SYNTHESIS_PASS part=',log,re.M) and not re.search(r'^ERROR:',log,re.M)
    primitive=read(work/'primitive_counts.txt')
    assert 'Latch_count=0' in primitive and 'DSP48E2=16' in primitive
    part=re.search(r'^Part=(\S+)',primitive,re.M)[1]
    assert 'vu9p' in part
    out['synthesis']={'top':'npu_top','part':part,'board_confirmed':False,'source_hashes_match':True,
        'latches':0,'utilization':utilization(work/'utilization_synth.rpt'),
        'timing':timing(work/'timing_synth.rpt'),
        'warnings_in_log':[s for s in log.splitlines() if s.startswith(('WARNING:','CRITICAL WARNING:'))]}
    assert out['synthesis']['utilization']['DSP']==16
    assert out['synthesis']['timing']['checks']['no_clock']==0
    assert out['synthesis']['timing']['checks']['unconstrained_internal_endpoints']==0
    assert out['synthesis']['timing']['setup_failing_endpoints']==0
    assert out['synthesis']['timing']['hold_failing_endpoints']==0
    assert not re.search(r'^CRITICAL WARNING:',log,re.M)
    if re.search(r'^OOC_IMPLEMENTATION_FINISHED$',log,re.M):
        route=read(work/'route_status_ooc.rpt')
        route_counts={}
        for key,label in [('routable_nets','routable nets'),('fully_routed_nets','fully routed nets'),
                          ('routing_errors','nets with routing errors'),('explicit_gaps','nets with explicit gaps')]:
            match=re.search(r'# of '+label+r'\.+\s*:\s*(\d+)',route)
            assert match
            route_counts[key]=int(match[1])
        assert route_counts['routing_errors']==0
        drc=read(work/'drc_ooc.rpt')
        out['ooc']={'completed':True,'utilization':utilization(work/'utilization_ooc.rpt'),
                    'timing':timing(work/'timing_ooc.rpt'),'route_status':route_counts,
                    'drc_design_state':re.search(r'\| Design State\s*:\s*([^\r\n]+)',drc)[1].strip(),
                    'drc_checks':[{'rule':rule,'severity':severity,'description':desc.strip(),'checks':int(count)}
                        for rule,severity,desc,count in re.findall(r'^\|\s*([A-Z][A-Z0-9_-]+)\s*\|\s*(Warning|Error|Critical Warning)\s*\|\s*([^|]+)\s*\|\s*(\d+)\s*\|',drc,re.M)]}
        assert out['ooc']['timing']['checks']['no_clock']==0
        assert out['ooc']['timing']['checks']['unconstrained_internal_endpoints']==0
        assert out['ooc']['timing']['setup_failing_endpoints']==0
        assert out['ooc']['timing']['hold_failing_endpoints']==0
    else:
        out['ooc']={'completed':False}
    negative=root/'build/sim_npu_4x4_k8_q4_negative'
    out['negative_probe']={'executed':False}
    if (negative/'observed_exit_code.txt').exists():
        code=int(read(negative/'observed_exit_code.txt'))
        assert code!=0 and 'NPU_CHECK_FAILED' in read(negative/'run.log') and not (negative/'PASS.txt').exists()
        out['negative_probe']={'executed':True,'observed_powershell_exit_code':code,'failure_detected':True}
    out['totals']={'ordered_batch_descriptors':72,'successful_batch_jobs':48,'rejected_batch_jobs':24,
                   'post_reset_successful_jobs':4,'output_comparisons':2382}
    (root/'build/npu_summary.json').write_text(json.dumps(out,indent=2,ensure_ascii=False)+'\n',encoding='utf8')
    print('NPU_ARTIFACT_AUDIT_PASS descriptors=72 comparisons=2382')
    brief=dict(out['synthesis'])
    brief.pop('warnings_in_log',None)
    print(json.dumps({'synthesis':brief,'ooc':out['ooc']},indent=2))


if __name__=='__main__':
    main()
