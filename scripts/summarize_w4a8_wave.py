"""Audit incremental wide-input W4A8 implementation and measured ablation results."""
import csv,hashlib,json,re,sys
from pathlib import Path
sys.dont_write_bytecode=True
from summarize import read,utilization as legacy_utilization,timing
from reuse_traffic import traffic
ROOT=Path(__file__).resolve().parents[1]
CONFIGS=[('g4',4,4,8,32,1,1),('g8',8,8,8,32,1,1),
         ('t4',4,4,8,32,1,0),('t8',8,8,8,32,1,0),
         ('alt',2,3,5,12,1,1),('words8',8,8,19,32,1,1),
         ('single',4,4,8,32,0,1),('one',1,1,8,32,1,1)]

def utilization(path):
    u=legacy_utilization(path)
    text=read(path)
    u['LUT_memory']=u.pop('LUTRAM')
    u['LUTRAM']=int(re.search(r'^\|\s+LUT as Distributed RAM\s*\|\s*(\d+)',text,re.M)[1])
    u['SRL']=int(re.search(r'^\|\s+LUT as Shift Register\s*\|\s*(\d+)',text,re.M)[1])
    assert u['LUT_memory']==u['LUTRAM']+u['SRL']
    return u
def identity(work):
    saved=json.loads(read(work/'source_inputs.json'))
    for name,digest in saved['files'].items():
        assert hashlib.sha256((ROOT/name).read_bytes()).hexdigest()==digest,name
    return saved
def table(headers,rows):
    return '| '+' | '.join(headers)+' |\n|'+ '|'.join(['---']*len(headers))+'|\n'+''.join('| '+' | '.join(map(str,r))+' |\n' for r in rows)
def main():
    summary={'scope':'Group-continuous 4x4/8x8 W4A8 systolic wave; no DDR','simulations':[]}
    for name,rows,cols,tk,group,db,stream in CONFIGS:
        bus=8;reuse=1;once=1;pack=1;overlap=1;pipeline=1;systolic=1
        work=ROOT/f'build/sim_w4a8_wave_{name}'
        identity(work)
        assert (work/'vectors.txt').read_bytes()==(ROOT/f'build/w4a8_systolic_vectors/group{group}.txt').read_bytes()
        model=json.loads(read(ROOT/f'build/w4a8_systolic_vectors/group{group}.json'))
        log=read(work/'run.log')
        assert read(work/'PASS.txt').strip()=='PASS' and not re.search(r'Fatal:|FAILED|TIMEOUT|^ERROR:',log,re.M)
        mt=re.search(r'W4A8_WAVE_TESTS_PASS rows=(\d+) cols=(\d+) tile=(\d+) group=(\d+) db=(\d+) tasks=(\d+) outputs=(\d+) psums=(\d+) checks=(\d+) overlap=(\d+) held_inputs=(\d+) bytes=(\d+) scale_once=(\d+) pack=(\d+) dual_writes=(\d+) holey_keeps=(\d+) odd_k=(\d+) post_overlap=(\d+) pipeline=(\d+) scaled=(\d+) full_queue=(\d+) held_pipe=(\d+) post_resets=(\d+) a_reuse=(\d+) cache_hits=(\d+) cache_writes=(\d+) cache_switches=(\d+) systolic=(\d+) held_array=(\d+) drain_checks=(\d+) array_resets=(\d+) group_stream=(\d+) shadow_checks=(\d+) seam_holds=(\d+) reclaimed_writes=(\d+) seam_resets=(\d+) seam_resumes=(\d+)',log)
        assert mt and tuple(map(int,mt.group(1,2,3,4,5,12,13,14,18,19,24,28)))==(rows,cols,tk,group,db,bus,once,pack,overlap,pipeline,reuse,systolic)
        records=[{k:int(v) for k,v in r.items()} for r in csv.DictReader((work/'results.csv').open(encoding='utf-8-sig'))]
        extra_reset=1 if rows+cols>2 else 0
        seam_extra=2 if stream and rows+cols>2 else 0
        expected=[(i,0,j) for i in range(15) for j in range(3)]
        expected[33:33]=[(10,1,2),(10,1,0),(10,1,0),(10,1,0)]+[(10,1,0)]*extra_reset+([(10,1,1),(10,1,0)] if seam_extra else [])
        assert len(records)==49+extra_reset+seam_extra and int(mt[6])==49+extra_reset+seam_extra and int(mt[7])==1407+27*(extra_reset+seam_extra)
        cases=model['cases']
        assert int(mt[8])==3*sum(c['m']*c['n']*c['groups'] for c in cases)+(4+extra_reset+seam_extra)*cases[10]['m']*cases[10]['n']*cases[10]['groups']
        for r,(cid,rec,mode) in zip(records,expected):
            assert (r['case_id'],r['recovery'],r['mode'])==(cid,rec,mode)
            c=cases[cid]
            assert (r['M'],r['N'],r['K'])==(c['m'],c['n'],c['k'])
            assert tuple(r[k] for k in ('ROWS','COLS','TILE_K','GROUP_SIZE','DOUBLE_BUFFER','BUS_BYTES','SCALE_ONCE','PACK_COLS','POST_OVERLAP','POST_PIPELINE','A_REUSE','SYSTOLIC','GROUP_STREAM'))==(rows,cols,tk,group,db,bus,once,pack,overlap,pipeline,reuse,systolic,stream)
            pred=traffic(c['m'],c['n'],c['k'],rows,cols,tk,group,bus,once,pack,reuse)
            for key,value in pred.items():
                if key!='tiles':assert r[key]==value,(name,cid,key,r[key],value)
            assert r['array_cycles']+r['array_pause_cycles']+r['input_wait_cycles']+r['output_wait_cycles']+r['psum_wait_cycles']+r['post_drain_cycles']<=r['total_cycles']
            assert 0<=r['overlap_cycles']<=r['compute_cycles']
            assert r['padding_bytes']+r['weight_bytes']+r['activation_bytes']+r['scale_bytes']==r['input_beats']*bus
            count=((c['m']+rows-1)//rows)*((c['n']+cols-1)//cols)*c['groups']
            assert r['psum_groups']==count and r['post_issue_cycles']==count*rows*cols
            assert r['post_retire_cycles']==r['post_issue_cycles']
            output_tiles=((c['m']+rows-1)//rows)*((c['n']+cols-1)//cols)
            fixed=2*rows*cols*output_tiles+2*pred['tiles']+(rows*cols+2)*count+2*c['m']*c['n']+1
            assert r['total_cycles']==fixed+r['array_cycles']+r['array_pause_cycles']+r['input_wait_cycles']+r['output_wait_cycles']+r['psum_wait_cycles']+r['post_drain_cycles'],('cycle classification',name,cid,r)
            assert r['array_drain_cycles']==(rows+cols-2)*(count if stream else pred['tiles'])
            assert r['tile_handoffs']==(pred['tiles']-count if stream else 0)
            assert r['wave_hold_cycles']==2*r['tile_handoffs']+r['wave_input_wait_cycles']
            assert r['wave_input_wait_cycles']<=r['input_wait_cycles']
            assert r['array_cycles']==r['compute_cycles']+r['array_drain_cycles']
            assert 0<r['array_mac_cycles']<=r['array_cycles']
            assert r['valid_macs']<=rows*cols*r['array_mac_cycles']
            assert 0<=r['compute_post_overlap_cycles']<=min(r['compute_cycles'],r['post_active_cycles'])
            if not overlap:assert r['compute_post_overlap_cycles']==0
            if not db:assert r['overlap_cycles']==0
        assert int(mt[11])>0
        if db:assert int(mt[10])>0
        assert int(mt[20])==int(mt[8]) and int(mt[22])>0 and int(mt[23])==1
        if overlap:assert int(mt[21])>0
        assert int(mt[24])==reuse and int(mt[28])==systolic and int(mt[29])>0 and int(mt[31])==extra_reset
        assert int(mt[32])==stream and int(mt[33])>0
        if stream:assert int(mt[34])>0 and int(mt[35])>0
        assert int(mt[36])==int(mt[37])==(1 if seam_extra else 0)
        if systolic and rows+cols>2:assert int(mt[30])>0
        if reuse:assert int(mt[25])>0 and int(mt[26])>0 and int(mt[27])>0
        if pack and cols>1 and bus==8:
            assert int(mt[15])>0 and int(mt[16])>0
        if tk%2:assert int(mt[17])>0
        summary['simulations'].append(dict(name=name,ROWS=rows,COLS=cols,TILE_K=tk,GROUP_SIZE=group,DOUBLE_BUFFER=db,BUS_BYTES=bus,SCALE_ONCE=once,PACK_COLS=pack,POST_OVERLAP=overlap,POST_PIPELINE=pipeline,A_REUSE=reuse,SYSTOLIC=systolic,GROUP_STREAM=stream,shadow_checks=int(mt[33]),seam_holds=int(mt[34]),reclaimed_writes=int(mt[35]),seam_resets=int(mt[36]),seam_resumes=int(mt[37]),held_array_checks=int(mt[29]),drain_checks=int(mt[30]),array_resets=int(mt[31]),cache_hits=int(mt[25]),cache_writes=int(mt[26]),cache_switches=int(mt[27]),scaled_checks=int(mt[20]),full_queue_checks=int(mt[21]),held_pipe_checks=int(mt[22]),post_resets=int(mt[23]),dual_writes=int(mt[15]),holey_keeps=int(mt[16]),odd_k=int(mt[17]),tasks=49+extra_reset+seam_extra,outputs=1407+27*(extra_reset+seam_extra),psums=int(mt[8]),checks=int(mt[9]),cycles=records))

    baseline={}
    for name in ('s4','s8','b4','b8'):
        work=ROOT/f'build/sim_w4a8_systolic_{name}';identity(work)
        assert read(work/'PASS.txt').strip()=='PASS'
        baseline[name]=[{k:int(v) for k,v in r.items()} for r in csv.DictReader((work/'results.csv').open(encoding='utf-8-sig'))]
    summary['baseline']=baseline
    for name,previous in [('t4','s4'),('t8','s8')]:
        current=next(x for x in summary['simulations'] if x['name']==name)
        assert len(current['cycles'])==len(baseline[previous])
        for r,p in zip(current['cycles'],baseline[previous]):
            for field in p:assert r[field]==p[field],('exact tile-drain baseline',name,field)
    for current in summary['simulations']:
        if current['name'] not in ('g4','g8'):continue
        previous=baseline['s4' if current['name']=='g4' else 's8']
        for r in current['cycles']:
            if r['recovery']:continue
            p=next(p for p in previous if (p['case_id'],p['mode'],p['recovery'])==(r['case_id'],r['mode'],0))
            for field in ('weight_bytes','activation_bytes','scale_bytes','valid_macs','compute_cycles','input_beats','padding_bytes'):
                assert r[field]==p[field],('same data/arithmetic',field)
    summary['totals']={k:sum(s[k] for s in summary['simulations']) for k in ('tasks','outputs','psums','checks')}
    summary['eda']=[]
    for name,size,systolic in [('g4',4,1),('g8',8,1)]:
        work=ROOT/f'build/synth_w4a8_wave_{name}'
        eda=dict(name=name,size=size,systolic=systolic,synthesis_completed=False,ooc_completed=False)
        if (work/'primitive_counts.txt').exists():
            saved=identity(work)
            assert (saved['rows'],saved['cols'],saved['systolic'],saved['group_stream'])==(size,size,systolic,1)
            log=read(work/'synth_w4a8_wave.log')
            assert re.search(r'^W4A8_WAVE_SYNTHESIS_PASS',log,re.M) and not re.search(r'^ERROR:|^CRITICAL WARNING:',log,re.M)
            pc=read(work/'primitive_counts.txt');assert 'Latch_count=0' in pc and 'Blackbox_count=0' in pc
            part=re.search(r'^Part=(\S+)',pc,re.M)[1];assert part=='xcvu9p-flga2104-2L-e'
            u=utilization(work/'utilization_synth.rpt');t=timing(work/'timing_synth.rpt')
            for key in ('no_clock','unconstrained_internal_endpoints','latch_loops'):assert t['checks'][key]==0
            ram=read(work/'ram_synth.rpt')
            cache=re.findall(r'^\|\s+(activation_cache\.row_bank\[\d+\]\.ram/mem_reg)\s*\|\s*(RAMB36E2)\s*\|\s*BLOCK\s*\|\s*(\d+)\s*\|\s*(\d+)',ram,re.M)
            assert len(cache)==size and all(int(x[3])==32768 for x in cache)
            dsp=read(work/'dsp_mapping.txt').splitlines()[::2]
            assert sum('array_core' in n for n in dsp)==size*size and len(dsp)==int(u['DSP'])
            eda.update(synthesis_completed=True,part=part,utilization=u,timing=t,activation_cache_mapping=cache,dsp_instances=dsp,warnings=[l for l in log.splitlines() if l.startswith(('WARNING:','CRITICAL WARNING:'))])
            if re.search(r'^W4A8_WAVE_OOC_FINISHED',log,re.M):
                route=read(work/'route_status_ooc.rpt');drc=read(work/'drc_ooc.rpt')
                rc={key:int(re.search(r'# of '+label+r'\.+\s*:\s*(\d+)',route)[1]) for key,label in [('routable_nets','routable nets'),('fully_routed_nets','fully routed nets'),('routing_errors','nets with routing errors'),('explicit_gaps','nets with explicit gaps')]}
                assert rc['routing_errors']==0 and rc['routable_nets']==rc['fully_routed_nets']
                drcs=[dict(rule=r,severity=se,description=ds.strip(),checks=int(ct)) for r,se,ds,ct in re.findall(r'^\|\s*([A-Z][A-Z0-9_-]+)\s*\|\s*(Warning|Error|Critical Warning)\s*\|\s*([^|]+)\s*\|\s*(\d+)\s*\|',drc,re.M)]
                assert not any(x['severity'] in ('Error','Critical Warning') for x in drcs)
                t=timing(work/'timing_ooc.rpt')
                eda.update(ooc_completed=True,ooc_utilization=utilization(work/'utilization_ooc.rpt'),ooc_timing=t,route_status=rc,drc=drcs,design_state=re.search(r'\| Design State\s*:\s*([^\r\n]+)',drc)[1].strip(),internal_target_met=t['setup_failing_endpoints']==t['hold_failing_endpoints']==0)
        summary['eda'].append(eda)
    neg=ROOT/'build/sim_w4a8_wave_g4_negative';summary['negative_probe']={'executed':False}
    if (neg/'observed_exit_code.txt').exists():
        identity(neg);code=int(read(neg/'observed_exit_code.txt'))
        assert code!=0 and 'W4A8_WAVE_CHECK_FAILED' in read(neg/'run.log') and not (neg/'PASS.txt').exists()
        summary['negative_probe']=dict(executed=True,exit_code=code)
    summary['part']='xcvu9p-flga2104-2L-e (temporary evaluation; board unspecified)'
    (ROOT/'build/w4a8_wave_summary.json').write_text(json.dumps(summary,ensure_ascii=False,indent=2)+'\n',encoding='utf8')
    report(summary)
    files=['rtl/w4a8_wave.sv','rtl/systolic_array.sv','rtl/systolic_pe.sv',
           'tb/tb_w4a8_wave.sv','tb/w4a8_reuse_memory.sv','model/w4a8_systolic_vectors.py',
           'scripts/run_w4a8_wave.ps1','scripts/synth_w4a8_wave.tcl',
           'scripts/summarize_w4a8_wave.py','scripts/run_w4a8_wave_vcs.sh',
           'docs/w4a8_wave_architecture.md','docs/w4a8_wave_validation.md',
           'docs/w4a8_wave_performance.md','docs/w4a8_wave_brief.md','docs/w4a8_next_steps.md','README.md','config/project.json']
    delivery=dict(scope=summary['scope'],simulation_pass=True,totals=summary['totals'],
                  part=summary['part'],negative_probe=summary['negative_probe'],
                  eda=[{k:e.get(k) for k in ('name','synthesis_completed','ooc_completed','internal_target_met')} for e in summary['eda']],
                  vcs_compilation='not run; no installation discovered',files={})
    for name in files:
        data=(ROOT/name).read_bytes()
        delivery['files'][name]=dict(bytes=len(data),sha256=hashlib.sha256(data).hexdigest())
    delivery['pass']=all(e.get('internal_target_met',False) for e in summary['eda']) and summary['negative_probe']['executed']
    (ROOT/'build/w4a8_wave_delivery.json').write_text(json.dumps(delivery,ensure_ascii=False,indent=2)+'\n',encoding='utf8')
    print('W4A8_WAVE_ARTIFACT_AUDIT_PASS '+json.dumps(summary['totals']))
    print(json.dumps({'eda':[{k:v for k,v in x.items() if k not in ('warnings','dsp_instances','activation_cache_mapping')} for x in summary['eda']],'negative':summary['negative_probe']},indent=2))
def record(sim,cid,mode):
    return next(r for r in sim['cycles'] if (r['case_id'],r['mode'],r['recovery'])==(cid,mode,0))

def report(s):
    text='# Group 内连续脉动波前：实际验证报告\n\n'
    text+='新增w4a8_wave，保留w4a8_systolic逐tile排空与广播基线；systolic_pe/array及数值向量未改。Windows PowerShell5.1、Python3.13.5、Vivado/XSim2025.2 build6299465。临时评估part xcvu9p-flga2104-2L-e，板卡/最终封装与速度等级未确认。\n\n'
    text+='## 已运行验证\n\n'
    text+=table(['配置','阵列','tile/group','group连续','任务','输出','psum/scale比较','逐PE状态检查','接缝保持','旧bank重写','接缝复位/恢复'],[[x['name'],f"{x['ROWS']}×{x['COLS']}",f"{x['TILE_K']}/{x['GROUP_SIZE']}",x['GROUP_STREAM'],x['tasks'],x['outputs'],x['psums'],x['shadow_checks'],x['seam_holds'],x['reclaimed_writes'],f"{x['seam_resets']}/{x['seam_resumes']}"] for x in s['simulations']])
    text+=f"\n合计{s['totals']['tasks']}任务、{s['totals']['outputs']}输出、{s['totals']['psums']}组psum和scaled乘积逐项一致。独立历史参考按逻辑advance编号存原始矩阵A/W，PE(r,c)取t−r−c的注入历史，逐PE逐拍比较fire与INT32 sum，包括WAIT_TILE/PRIME冻结。该参考不使用DUT乘积作为golden。\n\n"
    text+='覆盖原15个数值/性能用例：零、边界、全部INT4编码、不同group scale、随机、非整块/不完整group、M=1/M>1、满8×8及尾块。额外强制输入饥饿使波前滞留在接缝20拍后恢复，以及接缝保持时复位恢复；原RUN/输出/post流水/末组排空复位、满psum队列、array/post/input暂停和输出背压均保留。旧bank重新LOADING写入时有在途波前的情况已覆盖。t4/t8所有CSV字段逐项复现上一轮s4/s8，包括暂停和恢复任务；原基线源码哈希一致。\n\n'
    text+='每任务200000拍和全局20ms超时；自检失败fatal与脚本PASS检查转非零。自动错误golden探针：'+json.dumps(s['negative_probe'])+'。只RTL仿真；综合网表仿真未运行。\n\n'
    text+='## 数值三层\n\nA：所有RTL输出/组psum/scaled乘积对位精确模型一致。B/C沿用相同向量，没有改量化算法；为合成浮点线性层，不是模型质量结论。满8×8 Prefill的实际参考误差：\n\n'
    errors=[]
    for group in (32,12):
        c=json.loads(read(ROOT/f'build/w4a8_systolic_vectors/group{group}.json'))['cases'][12]
        errors.append(dict(group=group,B=c['B_fixed_vs_float_quant'],C=c['C_quant_vs_original']))
    text+='~~~json\n'+json.dumps(errors,ensure_ascii=False,indent=2)+'\n~~~\n\n'
    text+='## 器件资源与内部时序\n\n'
    rows=[]
    for e in s['eda']:
        if not e['synthesis_completed']:rows.append([e['name'],'未运行/完成',*['—']*10]);continue
        u=e['utilization'];t=e['timing'];rows.append([e['name'],'综合',*[u[k] for k in ('LUT','FF','DSP','RAMB18','RAMB36','LUTRAM','SRL','URAM')],t['WNS_ns'],t['WHS_ns']])
        if e['ooc_completed']:
            u=e['ooc_utilization'];t=e['ooc_timing'];rows.append([e['name'],'OOC',*[u[k] for k in ('LUT','FF','DSP','RAMB18','RAMB36','LUTRAM','SRL','URAM')],t['WNS_ns'],t['WHS_ns']])
    text+=table(['配置','阶段','LUT','FF','DSP','RAMB18','RAMB36','LUTRAM','SRL','URAM','WNS ns','WHS ns'],rows)
    text+='\n默认tile8/group32、4×4/8×8 GROUP_STREAM=1运行器件工具，其他配置只仿真。两类RAM均为真实有限端口同步读，早释放bank没有新增RAM读写端口。每行512×64bit激活缓存实际RAMB36；W为LUTRAM；SRL单列，不能合计成RAM。DSP实例检查PE数量16/64，scale另计；latch/blackbox=0。10ns与虚拟BUFGCE_X0Y0仅内部OOC评估，无管脚/I/O delay；外部port不能据此报告板上频率。\n\n'
    for e in s['eda']:
        text+='### '+e['name']+' 实际工具证据\n\n~~~json\n'+json.dumps({k:v for k,v in e.items() if k not in ('warnings','dsp_instances')},ensure_ascii=False,indent=2)+'\n~~~\n\n'
        if e['synthesis_completed']:text+='完整warning列表：\n\n~~~text\n'+'\n'.join(e['warnings'])+'\n~~~\n\n'
    text+='## 范围与限制\n\n已实现且验证：表中配置、逐PE对齐/冻结、流量和周期、bank重写/输入饥饿/复位；器件工具状态如上。未验证：最大M/N/K、未列参数、综合网表仿真、VCS编译运行。可配置VCS入口提供且Bash -n检查；本机未发现VCS，不安装或申请许可证。未来：消除READY tile的WAIT/PRIME边界停顿、有效槽psum保存、输出tile流水、Decode专用映射、统一NPU队列、DDR/完整模型。\n\n'
    text+='“group连续”指同group不排空、不清除在途token，当前tile切换仍冻结两个固定控制拍，输入不READY还会增加冻结等待；不是每墙钟拍都注入，也未自动推进bubble以排空。新wave_hold统计是既有固定/输入等待周期的子集，不能重复加到总周期。数值格式与输出次序不变。\n'
    (ROOT/'docs/w4a8_wave_validation.md').write_text(text,encoding='utf8')
    perf='# Group 连续波前：性能对照\n\n'
    rows=[]
    for cid in (4,5,12,13,14):
        for mode in (0,1,2):
            for name,old,broadcast in [('g4','s4','b4'),('g8','s8','b8')]:
                sim=next(x for x in s['simulations'] if x['name']==name);r=record(sim,cid,mode)
                p=next(p for p in s['baseline'][old] if (p['case_id'],p['mode'],p['recovery'])==(cid,mode,0))
                b=next(p for p in s['baseline'][broadcast] if (p['case_id'],p['mode'],p['recovery'])==(cid,mode,0))
                rows.append([cid,name,mode,p['total_cycles'],r['total_cycles'],b['total_cycles'],f"{100*(1-r['total_cycles']/p['total_cycles']):.2f}%",p['array_drain_cycles'],r['array_drain_cycles'],r['tile_handoffs'],r['wave_hold_cycles'],r['wave_input_wait_cycles'],r['input_wait_cycles'],r['input_beats'],f"{100*r['valid_macs']/(r['ROWS']*r['COLS']*r['total_cycles']):.2f}%"])
    perf+=table(['case','配置','模式','逐tile周期','group周期','广播周期','周期减少','旧排空','新排空','接缝次数','接缝冻结','其中等输入','总等输入','beat','端到端MAC利用率'],rows)
    perf+='\ncase4=1×13×96 Decode、5=4×12×96 Prefill、12=8×16×96满8×8、13=1×17×96、14=9×11×67尾块。模式0连续，模式1首延迟5/有限物理beat间隔，模式2固定LFSR和周期暂停；模式2绝对tick相位会随周期变化，不是逐拍同阻塞回放。全部为TB条件，不是DDR吞吐/板上性能。\n\n'
    rows=[]
    for name in ('alt','words8','single','one'):
        x=next(x for x in s['simulations'] if x['name']==name)
        for mode in (0,1):
            r=record(x,12,mode);rows.append([name,mode,r['total_cycles'],r['array_drain_cycles'],r['input_wait_cycles'],r['input_beats'],r['padding_bytes']])
    perf+='## 附加消融：满8×8用例\n\n'+table(['配置','模式','总周期','排空','等输入','beat','padding'],rows)
    perf+='\nD=ROWS+COLS−2。逐tile排空为D×tile_count；group排空为D×output_tile_count×group_count。handoffs=tile_count−物理group_count。wave_hold_cycles=2×handoffs+wave_input_wait_cycles，含WAIT_TILE READY交付和PRIME同步首读；wave_input_wait是input_wait子集。每条CSV独立审计这些等式。\n\n'
    perf+='总周期闭式分类不变：固定开销=2RC×输出tile数+2×请求tile数+(RC+2)×group数+2MN+1；total=固定+array_cycles+array_pause+等输入+等输出+psum满等待+post drain。array_cycles=compute_cycles+array_drain；valid_macs累计实际有效PE firing。复用同数据/scale/MAC，未减少算法工作或改变精度。波前/接缝冻结指标为子集，不能重复相加。默认理论16/64MAC每推进拍、100MHz目标1.6/6.4GMAC/s；实际频率/DDR/token吞吐没有测量。\n\n'
    perf+='相比上一轮，减少排空也会缩短预取窗口，输入等待可能增加；总周期收益必须用实测而非只减排空拍数。group仍有一次D拍开销，tile切换还需固定两拍，RC逐槽保存/scale/输出仍串行，是下一轮优化对象。\n'
    (ROOT/'docs/w4a8_wave_performance.md').write_text(perf,encoding='utf8')
    brief='# Group 连续波前：内部交流摘要\n\n新增w4a8_wave，保持4×4/8×8 PE、激活缓存、packed W双bank、双psum和scale。tile末向量全部进入寄存链后释放bank，WAIT_TILE/PRIME冻结旧token，新tile首向量沿相同advance序列继续；只group末排空再snapshot/scale。\n\n'
    brief+=f"实际{s['totals']['tasks']}任务/{s['totals']['outputs']}输出/{s['totals']['psums']}组psum/scaled一致，并用独立原矩阵历史逐PE每拍检查；输入饥饿恢复、滞留波前复位和bank重写有定向覆盖。\n\n"
    rows=[]
    for cid in (4,5,12):
        for name,old in [('g4','s4'),('g8','s8')]:
            r=record(next(x for x in s['simulations'] if x['name']==name),cid,0)
            p=next(p for p in s['baseline'][old] if (p['case_id'],p['mode'],p['recovery'])==(cid,0,0))
            rows.append([cid,name,p['total_cycles'],r['total_cycles'],p['array_drain_cycles'],r['array_drain_cycles'],r['input_wait_cycles']])
    brief+=table(['case','配置','旧周期','新周期','旧排空','新排空','等输入'],rows)
    resources=[]
    for e in s['eda']:
        if e['synthesis_completed']:
            u=e['utilization'];resources.append([e['name'],int(u['LUT']),int(u['FF']),int(u['DSP']),int(u['RAMB36']),int(u['RAMB18']),e.get('ooc_timing',{}).get('WNS_ns','未运行/完成'),e.get('ooc_timing',{}).get('WHS_ns','未运行/完成')])
    brief+='\n临时VU9P/10ns内部评估，实际综合资源与实际OOC时序：\n\n'+table(['配置','LUT','FF','DSP','RAMB36','RAMB18','OOC WNS','OOC WHS'],resources)
    brief+='\n瓶颈变化：逐tile排空已消除，仍有输入饥饿、两拍tile交付/首读、group末波前、RC保存/后处理与输出串行。下一步优先减少有效槽保存/输出tile开销并衡量同group READY tile无缝预取；Decode另需N/K映射。无真实DDR/完整模型、无统一NPU descriptor适配，VCS/综合网表仿真未运行。\n'
    (ROOT/'docs/w4a8_wave_brief.md').write_text(brief,encoding='utf8')
if __name__=='__main__':main()
