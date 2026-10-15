"""Audit valid-slot correctness, exact ablation, independent cycles and EDA."""
import csv
import json
import re
import sys
sys.dont_write_bytecode=True
from summarize_requant import ROOT,identity,sha,text,utilization,timing,timing_checks
sys.path.insert(0,str(ROOT/'model'))
from w4a8_valid_reference import slot_plan

CONFIGS=[('v4',4,4,8,32,1,1),('v8',8,8,8,32,1,1),('alt',2,3,5,12,1,1),
         ('one',1,1,8,32,1,1),('single',4,4,8,32,0,1),('words8',8,8,19,32,1,1),
         ('base4',4,4,8,32,1,0),('base8',8,8,8,32,1,0)]


def records(path):
    return [{k:int(v) for k,v in r.items()} for r in csv.DictReader(path.open(encoding='utf-8-sig'))]


def main():
    summary=dict(scope='Valid coordinate traversal; preserved physical addresses/numerics/packet/wave',simulations=[],eda=[],probes=[],performance=[])
    totals=dict(tasks=0,outputs=0,psums=0,checks=0)
    for name,rows,cols,tile,group,db,valid in CONFIGS:
        work=ROOT/f'build/sim_w4a8_valid_{name}';ident=identity(work)
        assert (ident['rows'],ident['cols'],ident['group_size'],ident['valid_only'])==(rows,cols,group,valid)
        assert text(work/'PASS.txt').strip()=='PASS'
        for phase in ('compile','elaborate','run'):assert int(text(work/(phase+'.log.exit_code.txt')))==0
        assert sha(work/'valid_slot_monitor.svh')==sha(ROOT/'tb/valid_slot_monitor.svh')
        assert sha(work/'vectors.txt')==sha(ROOT/f'build/w4a8_systolic_vectors/group{group}.txt')
        log=text(work/'run.log');assert not re.search(r'^Fatal:|CHECK_FAILED|TIMEOUT|^ERROR:',log,re.M)
        match=re.search(r'^W4A8_VALID_TESTS_PASS ([^\r\n]+)',log,re.M);assert match
        counters={k:int(v) for k,v in re.findall(r'(\w+)=(\d+)',match[1])}
        assert (counters['rows'],counters['cols'],counters['tile'],counters['group'],counters['db'])==(rows,cols,tile,group,db)
        cases=json.loads(text(ROOT/f'build/w4a8_systolic_vectors/group{group}.json'))['cases']
        cycles=records(work/'results.csv');slots=records(work/'slots.csv')
        extra=3 if rows+cols>2 else 0
        expected=[(i,0,mode) for i in range(15) for mode in range(3)]
        expected[33:33]=[(10,1,2),(10,1,0),(10,1,0),(10,1,0)]+([(10,1,0),(10,1,1),(10,1,0)] if extra else [])
        assert len(cycles)==len(slots)==counters['tasks']==49+extra
        assert counters['outputs']==sum(cases[i]['m']*cases[i]['n'] for i,_,_ in expected)
        assert counters['psums']==sum(cases[i]['m']*cases[i]['n']*cases[i]['groups'] for i,_,_ in expected)
        for r,s,key in zip(cycles,slots,expected):
            assert tuple(r[k] for k in ('case_id','recovery','mode'))==key==tuple(s[k] for k in ('case_id','recovery','mode'))
            c=cases[key[0]];assert (r['M'],r['N'],r['K'])==(c['m'],c['n'],c['k'])
            assert tuple(r[k] for k in ('ROWS','COLS','TILE_K','GROUP_SIZE','DOUBLE_BUFFER','BUS_BYTES','SCALE_ONCE','PACK_COLS','POST_OVERLAP','POST_PIPELINE','A_REUSE','SYSTOLIC','GROUP_STREAM'))==(rows,cols,tile,group,db,8,1,1,1,1,1,1,1)
            plan=slot_plan(c['m'],c['n'],c['k'],rows,cols,tile,group,valid)
            for k in ('init_slots','out_req_slots','saved_slots','issued_slots','retired_slots'):assert s[k]==plan[k],(name,key,k,s[k],plan[k])
            assert s['VALID_ONLY']==valid
            for k,v in plan['packet'].items():
                if k!='tiles':assert r[k]==v,(name,key,k,r[k],v)
            assert r['psum_groups']==plan['physical_groups'] and r['post_issue_cycles']==r['post_retire_cycles']==plan['saved_slots']
            assert r['array_cycles']==r['compute_cycles']+r['array_drain_cycles']
            assert r['array_drain_cycles']==(rows+cols-2)*plan['physical_groups']
            assert r['tile_handoffs']==plan['packet']['tiles']-plan['physical_groups']
            assert r['wave_hold_cycles']==2*r['tile_handoffs']+r['wave_input_wait_cycles'] and r['wave_input_wait_cycles']<=r['input_wait_cycles']
            exclusive=sum(r[k] for k in ('array_cycles','array_pause_cycles','input_wait_cycles','output_wait_cycles','psum_wait_cycles','post_drain_cycles'))
            assert r['total_cycles']==plan['fixed_cycles']+exclusive,(name,key,'cycle closure',r['total_cycles'],plan['fixed_cycles'],exclusive)
            assert 0<=r['compute_post_overlap_cycles']<=min(r['compute_cycles'],r['post_active_cycles'])
        assert counters['post_resets']==1 and counters['held_pipe']>0 and counters['full_queue']>0 and counters['shadow_checks']>0
        assert counters['seam_resets']==counters['seam_resumes']==(1 if extra else 0)
        if db:assert counters['overlap']>0
        else:assert counters['overlap']==0
        for k in totals:totals[k]+=counters[k]
        summary['simulations'].append(dict(name=name,identity=ident,counters=counters,cycles=cycles,slots=slots,slot_csv_sha256=sha(work/'slots.csv'),result_csv_sha256=sha(work/'results.csv')))
    summary['totals']=totals
    for name,old in [('base4','g4'),('base8','g8')]:
        work=ROOT/f'build/sim_w4a8_wave_{old}';identity(work)
        current=next(s for s in summary['simulations'] if s['name']==name)['cycles']
        previous=records(work/'results.csv');assert current==previous,('exact full-slot ablation',name)
    for name,old in [('v4','g4'),('v8','g8'),('alt','alt'),('one','one'),('single','single'),('words8','words8')]:
        baseline=records(ROOT/f'build/sim_w4a8_wave_{old}/results.csv')
        current=next(s for s in summary['simulations'] if s['name']==name)['cycles']
        for r,b in zip(current,baseline):
            for k in ('case_id','recovery','mode','M','N','K','weight_bytes','activation_bytes','scale_bytes','valid_macs','compute_cycles','input_beats','padding_bytes','array_drain_cycles','tile_handoffs'):assert r[k]==b[k],(name,k)
            if r['case_id'] in (4,5,12,14) and not r['recovery']:
                summary['performance'].append(dict(config=name,case=r['case_id'],mode=r['mode'],dims=f"{r['M']}x{r['N']}x{r['K']}",baseline_cycles=b['total_cycles'],valid_cycles=r['total_cycles'],delta_cycles=b['total_cycles']-r['total_cycles'],reduction_percent=100*(b['total_cycles']-r['total_cycles'])/b['total_cycles'],baseline_post_slots=b['post_issue_cycles'],valid_post_slots=r['post_issue_cycles'],baseline_input_wait=b['input_wait_cycles'],valid_input_wait=r['input_wait_cycles']))
    for kind,marker in [('negative','W4A8_VALID_CHECK_FAILED'),('timeout','W4A8_VALID_GLOBAL_TIMEOUT')]:
        work=ROOT/f'build/sim_w4a8_valid_v4_{kind}';identity(work)
        code=int(text(work/'observed_exit_code.txt'));assert code!=0 and marker in text(work/'run.log') and not (work/'PASS.txt').exists()
        summary['probes'].append(dict(kind=kind,exit_code=code))
    if '--SimOnly' in sys.argv:
        # Read-only verification while the independent EDA process is running.
        print('W4A8_VALID_SIMULATION_AUDIT_PASS',json.dumps(dict(totals=totals,performance=[r for r in summary['performance'] if r['config'] in ('v4','v8') and r['mode']==0])))
        return
    for size in (4,8):
        work=ROOT/f'build/synth_w4a8_valid_v{size}'
        if not (work/'primitive_counts.txt').exists():summary['eda'].append(dict(size=size,synthesis_completed=False));continue
        ident=identity(work);log=text(work/'synth_w4a8_valid.log')
        assert int(text(work/'console.log.exit_code.txt'))==0
        assert re.search(r'^W4A8_VALID_SYNTHESIS_PASS',log,re.M) and not re.search(r'^ERROR:|^CRITICAL WARNING:',log,re.M)
        primitive={k:int(v) for k,v in re.findall(r'(\w+)=(\d+)',text(work/'primitive_counts.txt'))};assert primitive['Latch_count']==primitive['Blackbox_count']==0
        warnings=re.findall(r'^WARNING: (.*)$',log,re.M);(work/'warnings.txt').write_text('\n'.join(warnings)+'\n',encoding='utf8')
        e=dict(size=size,synthesis_completed=True,identity=ident,utilization=utilization(work/'utilization_synth.rpt'),timing=timing(work/'timing_synth.rpt'),timing_checks=timing_checks(work/'timing_synth.rpt'),primitives=primitive,warning_count=len(warnings),warning_codes=sorted(set(re.findall(r'^\[([^\]]+)\]','\n'.join(warnings),re.M))),ooc_completed=bool(re.search(r'^W4A8_VALID_OOC_FINISHED',log,re.M)))
        dsp=text(work/'dsp_mapping.txt').splitlines()[::2]
        assert sum('array_core' in line for line in dsp)==size*size and len(dsp)==e['utilization']['DSP']
        e['dsp_instances']=dsp
        if e['ooc_completed']:
            e['ooc_utilization']=utilization(work/'utilization_ooc.rpt');e['ooc_timing']=timing(work/'timing_ooc.rpt');e['ooc_checks']=timing_checks(work/'timing_ooc.rpt')
            assert e['ooc_timing']['setup_failing_endpoints']==e['ooc_timing']['hold_failing_endpoints']==0
            route=text(work/'route_status_ooc.rpt');e['route_counts']={}
            for k,label in [('routable','routable nets'),('fully_routed','fully routed nets'),('errors','nets with routing errors'),('gaps','nets with explicit gaps')]:e['route_counts'][k]=int(re.search(r'# of '+label+r'\.+\s*:\s*(\d+)',route)[1])
            assert e['route_counts']['errors']==0 and e['route_counts']['routable']==e['route_counts']['fully_routed']
            e['drc']=text(work/'drc_ooc.rpt');assert not re.search(r'\|\s*[^|]+\|\s*(?:Error|Critical Warning)\s*\|',e['drc'])
        summary['eda'].append(e)
    summary['files']={p:sha(ROOT/p) for p in ('rtl/w4a8_valid.sv','tb/tb_w4a8_valid.sv','tb/valid_slot_monitor.svh','model/w4a8_valid_reference.py','scripts/run_w4a8_valid.ps1','scripts/synth_w4a8_valid.tcl','scripts/summarize_w4a8_valid.py')}
    summary['preserved_wave_sha256']=sha(ROOT/'rtl/w4a8_wave.sv');summary['dynamic_delivery_sha256']=sha(ROOT/'build/dynamic_delivery.json');summary['pass']=True
    (ROOT/'build/w4a8_valid_delivery.json').write_text(json.dumps(summary,indent=2)+'\n',encoding='utf8')
    report(summary)
    print('W4A8_VALID_ARTIFACT_AUDIT_PASS',json.dumps(dict(totals=totals,eda=[{k:v for k,v in e.items() if k in ('size','utilization','ooc_timing')} for e in summary['eda']])))


def report(summary):
    lines=['# W4A8 有效槽：实际验证','', '由当前源码SHA、独立坐标/流量/周期模型、SV自检及实际Vivado产物生成；原数学golden未改。完整证据 [w4a8_valid_delivery.json](../build/w4a8_valid_delivery.json)。','',
        '| 配置 | 任务 | 输出 | psum/scale检查 | 自检项 |','|---|---:|---:|---:|---:|']
    for s in summary['simulations']:
        c=s['counters'];lines.append(f"| {s['name']} | {c['tasks']} | {c['outputs']} | {c['psums']} | {c['checks']} |")
    lines+=['', '包含逐PE数学历史与冻结、单周期同步psum/Y读写、宽累加RAW、双snapshot所有权、pipeline暂停、输出背压、连续任务、输入饥饿与复位；每任务200000拍、全局20ms超时。',
        'VALID_ONLY=0的base4/base8所有任务CSV字段与原g4/g8逐项一致。有效槽版本数据/scale/packet/MAC/推进/排空不变；只改变slot访问及由此带来的调度等待。','',
        '| 探针 | 实际退出码 |','|---|---:|']
    for p in summary['probes']:lines.append(f"| {p['kind']} | {p['exit_code']} |")
    lines+=['','| 阵列 | 阶段 | LUT | FF | DSP | RAMB36 | RAMB18 | WNS ns | WHS ns |','|---|---|---:|---:|---:|---:|---:|---:|---:|'];notes=[]
    for e in summary['eda']:
        if not e['synthesis_completed']:lines.append(f"| {e['size']} | 未运行 | — | — | — | — | — | — | — |");continue
        for stage,u,t in [('综合',e['utilization'],e['timing'])]+([('OOC',e['ooc_utilization'],e['ooc_timing'])] if e['ooc_completed'] else []):lines.append(f"| {e['size']} | {stage} | "+' | '.join(str(u[k]) for k in ('LUT','FF','DSP','RAMB36','RAMB18'))+f" | {t['WNS_ns']} | {t['WHS_ns']} |")
        notes+=['',f"{e['size']}×{e['size']}：latch/blackbox=0；警告 {e['warning_count']} 条，代码 {', '.join(e['warning_codes'])}；RAM/DSP细节见报告。"]
        if e['ooc_completed']:notes.append('路由 '+json.dumps(e['route_counts'])+'；内部setup/hold失败端点0。')
    lines+=notes+['','Vivado2025.2，临时xcvu9p-flga2104-2L-e，10ns内部OOC，无板级pin/IO delay，未证明板上频率。',
        '有效槽只减少访问/后处理次数，RAM容量仍为最大RC；物理地址和原数据宽度保持。未加入输出FIFO、tile双缓冲或改W4 decode。','']
    (ROOT/'docs/w4a8_valid_validation.md').write_text('\n'.join(lines),encoding='utf8')
    perf=['# 有效槽性能对照','', '| 配置 | M×N×K | 模式 | 原周期 | 有效槽周期 | 周期减少 | 减少% | 原post槽 | 新post槽 | 原等输入 | 新等输入 |','|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|']
    for r in summary['performance']:perf.append('| '+' | '.join(str(r[k]) for k in ('config','dims','mode','baseline_cycles','valid_cycles','delta_cycles'))+f" | {r['reduction_percent']:.2f} | "+' | '.join(str(r[k]) for k in ('baseline_post_slots','valid_post_slots','baseline_input_wait','valid_input_wait'))+' |')
    perf+=['','模式0连续、模式1有限物理带宽、模式2LFSR/周期暂停；模式2时间相位会随周期改变，不是同阻塞回放。调度窗口变短可增加等输入，性能下降也按原CSV报告。',
        '独立slots.csv审计：有效init/output请求均MN，saved/issued/retired均MN×ceil(K/GROUP_SIZE)。',
        'fixed=2×walk_output_slots+saved_slots+2×physical_groups+2×packet_tiles+2MN+1。',
        'total=fixed+array_cycles+array_pause+input_wait+output_wait+psum_wait+post_drain；波前接缝冻结与compute/post overlap是子集，不重复相加。','']
    (ROOT/'docs/w4a8_valid_performance.md').write_text('\n'.join(perf),encoding='utf8')


if __name__=='__main__':main()
