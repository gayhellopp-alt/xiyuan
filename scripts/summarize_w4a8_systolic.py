"""Audit incremental wide-input W4A8 implementation and measured ablation results."""
import csv,hashlib,json,re,sys
from pathlib import Path
sys.dont_write_bytecode=True
from summarize import read,utilization as legacy_utilization,timing
from reuse_traffic import traffic
ROOT=Path(__file__).resolve().parents[1]
CONFIGS=[('s4',4,4,8,32,1,1),('s8',8,8,8,32,1,1),
         ('b4',4,4,8,32,1,0),('b8',8,8,8,32,1,0),
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
    summary={'scope':'4x4 and 8x8 output-stationary systolic prototype with per-K-tile wave drain; no DDR','simulations':[]}
    for name,rows,cols,tk,group,db,systolic in CONFIGS:
        bus=8;reuse=1;once=1;pack=1;overlap=1;pipeline=1
        work=ROOT/f'build/sim_w4a8_systolic_{name}'
        identity(work)
        assert (work/'vectors.txt').read_bytes()==(ROOT/f'build/w4a8_systolic_vectors/group{group}.txt').read_bytes()
        model=json.loads(read(ROOT/f'build/w4a8_systolic_vectors/group{group}.json'))
        log=read(work/'run.log')
        assert read(work/'PASS.txt').strip()=='PASS' and not re.search(r'Fatal:|FAILED|TIMEOUT|^ERROR:',log,re.M)
        mt=re.search(r'W4A8_SYSTOLIC_TESTS_PASS rows=(\d+) cols=(\d+) tile=(\d+) group=(\d+) db=(\d+) tasks=(\d+) outputs=(\d+) psums=(\d+) checks=(\d+) overlap=(\d+) held_inputs=(\d+) bytes=(\d+) scale_once=(\d+) pack=(\d+) dual_writes=(\d+) holey_keeps=(\d+) odd_k=(\d+) post_overlap=(\d+) pipeline=(\d+) scaled=(\d+) full_queue=(\d+) held_pipe=(\d+) post_resets=(\d+) a_reuse=(\d+) cache_hits=(\d+) cache_writes=(\d+) cache_switches=(\d+) systolic=(\d+) held_array=(\d+) drain_checks=(\d+) array_resets=(\d+)',log)
        assert mt and tuple(map(int,mt.group(1,2,3,4,5,12,13,14,18,19,24,28)))==(rows,cols,tk,group,db,bus,once,pack,overlap,pipeline,reuse,systolic)
        records=[{k:int(v) for k,v in r.items()} for r in csv.DictReader((work/'results.csv').open(encoding='utf-8-sig'))]
        extra_reset=1 if systolic and rows+cols>2 else 0
        expected=[(i,0,j) for i in range(15) for j in range(3)]
        expected[33:33]=[(10,1,2),(10,1,0),(10,1,0),(10,1,0)]+[(10,1,0)]*extra_reset
        assert len(records)==49+extra_reset and int(mt[6])==49+extra_reset and int(mt[7])==1407+27*extra_reset
        cases=model['cases']
        assert int(mt[8])==3*sum(c['m']*c['n']*c['groups'] for c in cases)+(4+extra_reset)*cases[10]['m']*cases[10]['n']*cases[10]['groups']
        for r,(cid,rec,mode) in zip(records,expected):
            assert (r['case_id'],r['recovery'],r['mode'])==(cid,rec,mode)
            c=cases[cid]
            assert (r['M'],r['N'],r['K'])==(c['m'],c['n'],c['k'])
            assert tuple(r[k] for k in ('ROWS','COLS','TILE_K','GROUP_SIZE','DOUBLE_BUFFER','BUS_BYTES','SCALE_ONCE','PACK_COLS','POST_OVERLAP','POST_PIPELINE','A_REUSE','SYSTOLIC'))==(rows,cols,tk,group,db,bus,once,pack,overlap,pipeline,reuse,systolic)
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
            assert r['array_drain_cycles']==(rows+cols-2)*pred['tiles']*systolic
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
        if systolic and rows+cols>2:assert int(mt[30])>0
        if reuse:assert int(mt[25])>0 and int(mt[26])>0 and int(mt[27])>0
        if pack and cols>1 and bus==8:
            assert int(mt[15])>0 and int(mt[16])>0
        if tk%2:assert int(mt[17])>0
        summary['simulations'].append(dict(name=name,ROWS=rows,COLS=cols,TILE_K=tk,GROUP_SIZE=group,DOUBLE_BUFFER=db,BUS_BYTES=bus,SCALE_ONCE=once,PACK_COLS=pack,POST_OVERLAP=overlap,POST_PIPELINE=pipeline,A_REUSE=reuse,SYSTOLIC=systolic,held_array_checks=int(mt[29]),drain_checks=int(mt[30]),array_resets=int(mt[31]),cache_hits=int(mt[25]),cache_writes=int(mt[26]),cache_switches=int(mt[27]),scaled_checks=int(mt[20]),full_queue_checks=int(mt[21]),held_pipe_checks=int(mt[22]),post_resets=int(mt[23]),dual_writes=int(mt[15]),holey_keeps=int(mt[16]),odd_k=int(mt[17]),tasks=49+extra_reset,outputs=1407+27*extra_reset,psums=int(mt[8]),checks=int(mt[9]),cycles=records))

    summary['units']=[]
    for size in (4,8):
        work=ROOT/f'build/sim_systolic_unit{size}';identity(work)
        assert read(work/'PASS.txt').strip()=='PASS'
        log=read(work/'run.log');assert not re.search(r'Fatal:|FAILED|TIMEOUT|^ERROR:',log,re.M)
        mt=re.search(r'SYSTOLIC_UNIT_PASS rows=(\d+) cols=(\d+) groups=(\d+) checks=(\d+) held=(\d+) resets=(\d+)',log)
        assert mt and int(mt[1])==int(mt[2])==size and int(mt[3])==5 and int(mt[5])>0 and int(mt[6])==1
        summary['units'].append(dict(size=size,groups=5,checks=int(mt[4]),held=int(mt[5]),resets=int(mt[6])))
    old=ROOT/'build/sim_w4a8_reuse_reuse';identity(old)
    summary['broadcast4_baseline']=[{k:int(v) for k,v in r.items()} for r in csv.DictReader((old/'results.csv').open(encoding='utf-8-sig'))]
    b4=next(s for s in summary['simulations'] if s['name']=='b4')
    for r in b4['cycles']:
        if r['case_id']>=12 or r['recovery'] or r['mode']==2:continue
        previous=next(p for p in summary['broadcast4_baseline'] if (p['case_id'],p['mode'],p['recovery'])==(r['case_id'],r['mode'],0))
        for key in previous:assert r[key]==previous[key],('unchanged broadcast4 mode0/1',key,r,previous)
    summary['totals']={k:sum(s[k] for s in summary['simulations']) for k in ('tasks','outputs','psums','checks')}
    summary['eda']=[]
    for name,size,systolic in [('b4',4,0),('b8',8,0),('s4',4,1),('s8',8,1)]:
        work=ROOT/f'build/synth_w4a8_systolic_{name}'
        eda=dict(name=name,size=size,systolic=systolic,synthesis_completed=False,ooc_completed=False)
        if (work/'primitive_counts.txt').exists():
            saved=identity(work)
            assert (saved['rows'],saved['cols'],saved['systolic'])==(size,size,systolic)
            log=read(work/'synth_w4a8_systolic.log')
            assert re.search(r'^W4A8_SYSTOLIC_SYNTHESIS_PASS',log,re.M) and not re.search(r'^ERROR:|^CRITICAL WARNING:',log,re.M)
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
            if re.search(r'^W4A8_SYSTOLIC_OOC_FINISHED',log,re.M):
                route=read(work/'route_status_ooc.rpt');drc=read(work/'drc_ooc.rpt')
                rc={key:int(re.search(r'# of '+label+r'\.+\s*:\s*(\d+)',route)[1]) for key,label in [('routable_nets','routable nets'),('fully_routed_nets','fully routed nets'),('routing_errors','nets with routing errors'),('explicit_gaps','nets with explicit gaps')]}
                assert rc['routing_errors']==0 and rc['routable_nets']==rc['fully_routed_nets']
                drcs=[dict(rule=r,severity=se,description=ds.strip(),checks=int(ct)) for r,se,ds,ct in re.findall(r'^\|\s*([A-Z][A-Z0-9_-]+)\s*\|\s*(Warning|Error|Critical Warning)\s*\|\s*([^|]+)\s*\|\s*(\d+)\s*\|',drc,re.M)]
                assert not any(x['severity'] in ('Error','Critical Warning') for x in drcs)
                t=timing(work/'timing_ooc.rpt')
                eda.update(ooc_completed=True,ooc_utilization=utilization(work/'utilization_ooc.rpt'),ooc_timing=t,route_status=rc,drc=drcs,design_state=re.search(r'\| Design State\s*:\s*([^\r\n]+)',drc)[1].strip(),internal_target_met=t['setup_failing_endpoints']==t['hold_failing_endpoints']==0)
        summary['eda'].append(eda)
    neg=ROOT/'build/sim_w4a8_systolic_s4_negative';summary['negative_probe']={'executed':False}
    if (neg/'observed_exit_code.txt').exists():
        identity(neg);code=int(read(neg/'observed_exit_code.txt'))
        assert code!=0 and 'W4A8_SYSTOLIC_CHECK_FAILED' in read(neg/'run.log') and not (neg/'PASS.txt').exists()
        summary['negative_probe']=dict(executed=True,exit_code=code)
    summary['part']='xcvu9p-flga2104-2L-e (temporary evaluation; board unspecified)'
    (ROOT/'build/w4a8_systolic_summary.json').write_text(json.dumps(summary,ensure_ascii=False,indent=2)+'\n',encoding='utf8')
    report(summary)
    files=['rtl/systolic_pe.sv','rtl/systolic_array.sv','rtl/w4a8_systolic.sv',
           'tb/tb_systolic_array.sv','tb/tb_w4a8_systolic.sv','tb/w4a8_reuse_memory.sv',
           'model/w4a8_reference.py','model/w4a8_systolic_vectors.py',
           'scripts/run_systolic_unit.ps1','scripts/run_w4a8_systolic.ps1',
           'scripts/synth_w4a8_systolic.tcl','scripts/summarize_w4a8_systolic.py',
           'scripts/run_w4a8_systolic_vcs.sh','docs/w4a8_systolic_architecture.md',
           'docs/w4a8_systolic_validation.md','docs/w4a8_systolic_performance.md',
           'docs/w4a8_systolic_brief.md','README.md','config/project.json']
    delivery=dict(scope=summary['scope'],simulation_pass=True,units=summary['units'],totals=summary['totals'],
                  part=summary['part'],negative_probe=summary['negative_probe'],
                  eda=[{k:e.get(k) for k in ('name','synthesis_completed','ooc_completed','internal_target_met')} for e in summary['eda']],
                  vcs_compilation='not run; no installation discovered',files={})
    for name in files:
        data=(ROOT/name).read_bytes()
        delivery['files'][name]=dict(bytes=len(data),sha256=hashlib.sha256(data).hexdigest())
    delivery['pass']=all(e['synthesis_completed'] for e in summary['eda']) and all(e.get('internal_target_met',False) for e in summary['eda'] if e['systolic']) and summary['negative_probe']['executed']
    (ROOT/'build/w4a8_systolic_delivery.json').write_text(json.dumps(delivery,ensure_ascii=False,indent=2)+'\n',encoding='utf8')
    print('W4A8_SYSTOLIC_ARTIFACT_AUDIT_PASS '+json.dumps(summary['totals']))
    print(json.dumps({'units':summary['units'],'eda':[{k:v for k,v in x.items() if k not in ('warnings','dsp_instances','activation_cache_mapping')} for x in summary['eda']],'negative':summary['negative_probe']},indent=2))
def record(sim,cid,mode):
    return next(r for r in sim['cycles'] if (r['case_id'],r['mode'],r['recovery'])==(cid,mode,0))
def report(s):
    text='# 4×4 / 8×8 脉动阵列：实际验证报告\n\n'
    text+='新增 systolic_pe / systolic_array / w4a8_systolic，保留广播 w4a8_reuse；测试使用相同UQ4.12 scale与Q16.16输出合同。环境Windows PowerShell5.1、Python3.13.5、Vivado/XSim2025.2 Build6299465。VU9P临时评估part xcvu9p-flga2104-2L-e，板卡未确认。\n\n'
    text+='## 已运行自检\n\n'
    text+=table(['配置','阵列','K tile/group','数据流','任务','输出','group psum/scale比较','暂停检查','排空检查','排空中复位'],[[x['name'],f"{x['ROWS']}×{x['COLS']}",f"{x['TILE_K']}/{x['GROUP_SIZE']}",'systolic' if x['SYSTOLIC'] else 'broadcast',x['tasks'],x['outputs'],x['psums'],x['held_array_checks'],x['drain_checks'],x['array_resets']] for x in s['simulations']])
    text+=f"\n合计{s['totals']['tasks']}任务、{s['totals']['outputs']}输出、{s['totals']['psums']}组psum及scaled乘积逐项完全一致。4×4/8×8独立单元分别逐PE逐推进拍比较数学历史模型，检查r+c错位、边界INT8/INT4、K1、零、尾块、暂停时PE和入口skew持稳、跨段保留sum与有在途token时复位。\n\n"
    text+='集成覆盖既有12类数值用例，新增8×16×96满8×8 Prefill、1×17×96 Decode与9×11×67尾块。3供数模式、连续任务、busy start拒绝、输入/输出持稳、array/post分别暂停、双psum满队列、计算/输出/post流水/排空复位恢复。单元'+json.dumps(s['units'])+'。故障探针'+json.dumps(s['negative_probe'])+'。\n\n'
    text+='模式2新增array_pause，与历史模式2阻塞条件不同；b4模式0/1原12正常任务CSV逐字段复现原广播结果。数字正确性三层A/B/C沿用参考规格，额外用例误差见vector JSON；无真实模型质量结论。MAX_M/N64、MAX_K4096未全尺寸测试。单元1ms、集成20ms全局及每任务200000拍超时；fatal/PASS由脚本转非零。\n\n'
    text+='## 数值误差三层\n\nA为所有RTL/位精确输出、group psum和scaled乘积完全一致。B是编码定点scale对理想浮点量化scale，C是量化值对原始合成浮点矩阵；不是LLM准确率。代表性新增满8×8用例：\n\n'
    errors=[]
    for group in (32,12):
        c=json.loads(read(ROOT/f'build/w4a8_systolic_vectors/group{group}.json'))['cases'][12]
        errors.append(dict(group=group,case=c['name'],saturated_outputs=c['saturated_outputs'],B=c['B_fixed_vs_float_quant'],C=c['C_quant_vs_original']))
    text+='~~~json\n'+json.dumps(errors,ensure_ascii=False,indent=2)+'\n~~~\n\n'
    text+='## 数值与阵列时序\n\n每PE仍INT8×符号扩展INT4→signed16→signed32，整数sum按模2^32，group内跨K tile保留；group全部PE完成后交付两组snapshot，再乘sx/sw并累加signed64 Q24，输出shift8 ties-away舍入并饱和signed32 Q16.16。接口支持全阵列advance冻结，A/B/data/valid/skew/acc共同停止；group边界完整排空才clear或scale。每K tile排空D=ROWS+COLS−2，4×4为6拍，8×8为14拍，1×1为0拍。尾块本轮按物理阵列最大D排空，未缩短有效行列波前。\n\n'
    text+='## 器件综合与内部OOC\n\n'
    rows=[]
    for e in s['eda']:
        if not e['synthesis_completed']:rows.append([e['name'],'未运行/完成',*['—']*10]);continue
        u=e['utilization'];t=e['timing'];rows.append([e['name'],'综合',*[u[k] for k in ('LUT','FF','DSP','RAMB18','RAMB36','LUTRAM','SRL','URAM')],t['WNS_ns'],t['WHS_ns']])
        if e['ooc_completed']:
            u=e['ooc_utilization'];t=e['ooc_timing'];rows.append([e['name'],'OOC',*[u[k] for k in ('LUT','FF','DSP','RAMB18','RAMB36','LUTRAM','URAM')],t['WNS_ns'],t['WHS_ns']])
    text+=table(['配置','阶段','LUT','FF','DSP','RAMB18','RAMB36','LUTRAM','SRL','URAM','WNS ns','WHS ns'],rows)
    text+='\n本轮b4/b8只执行综合，OOC未运行；s4/s8执行综合及内部OOC，是否完成以上述实际标记为准。全部EDA使用10ns评估约束，虚拟BUFGCE_X0Y0。缓存每行512×64bit实际RAMB36、W为分布式RAM；8×8脉动的364个LUT memory实际拆为320 LUTRAM和44 SRL16E，表中已分列，不能全部称为RAM；两组psum和Y以各报告为准。primitive_counts检查latch/blackbox=0，dsp_mapping逐个实例确认MAC阵列DSP数量=ROWS×COLS。无板级管脚/I/O延迟；OOC边界未partial-route的外部port不作时序结论。只内部register path范围；不能宣称板上频率、DDR吞吐或加速比。\n\n'
    for e in s['eda']:
        text+='### '+e['name']+' 工具证据\n\n~~~json\n'+json.dumps({k:v for k,v in e.items() if k not in ('warnings','dsp_instances')},ensure_ascii=False,indent=2)+'\n~~~\n\n'
        if e['synthesis_completed']:text+='完整日志warning列表：\n\n~~~text\n'+'\n'.join(e['warnings'])+'\n~~~\n\n'
    text+='## 状态与限制\n\n已实现且验证：表中配置/工作负载及两尺寸单元；EDA完成情况如上。未验证：未列参数、最大维度、VCS编译运行；新增VCS入口已通过WSL Bash -n语法检查，Windows/WSL未发现VCS，未安装或申请许可证。未来：group连续注入后仅排空一次、输出tile流水、psum并行保存、Decode专用映射、统一NPU描述符/DDR。此次每K tile都排空且保持operand bank，是明确保守原型，不宣称已经优化的高吞吐脉动引擎；未改输出tile顺序。\n\n源/命令/CSV在build/sim_w4a8_systolic_*与build/sim_systolic_unit*，EDA在build/synth_w4a8_systolic_*，完整汇总build/w4a8_systolic_summary.json。\n'
    (ROOT/'docs/w4a8_systolic_validation.md').write_text(text,encoding='utf8')
    perf='# 4×4 / 8×8 广播与脉动性能对照\n\n相同小型W4A8路径、同一供数模型与数值向量。模式0连续，模式1固定首延迟5/物理8字节beat间隔与burst gap，模式2包含固定种子随机输入、输出背压及array/post暂停。模式2因任务周期不同绝对tick相位不同，不是逐拍相同阻塞回放。\n\n'
    rows=[]
    for cid in (4,5,12,13,14):
        for mode in (0,1,2):
            for name in ('b4','s4','b8','s8','words8'):
                x=next(x for x in s['simulations'] if x['name']==name);r=record(x,cid,mode)
                capacity=r['ROWS']*r['COLS']
                rows.append([cid,name,mode,f"{r['M']}×{r['N']}×{r['K']}",r['total_cycles'],r['compute_cycles'],r['array_drain_cycles'],r['array_pause_cycles'],r['array_mac_cycles'],r['input_wait_cycles'],r['post_drain_cycles'],r['input_beats'],r['valid_macs'],f"{100*r['valid_macs']/(capacity*r['array_cycles']):.2f}%",f"{100*r['valid_macs']/(capacity*r['total_cycles']):.2f}%"])
    perf+=table(['case','配置','模式','M×N×K','总周期','注入RUN','排空','array暂停','有MAC推进拍','等输入','post drain','输入beat','有效MAC','推进拍利用率','端到端利用率'],rows)
    perf+='\n有效MAC直接累计每PE valid firing，尾块无效槽不计。compute_cycles=接受输入向量的RUN推进拍；array_cycles=RUN+DRAIN推进拍；array_mac_cycles=至少一个有效PE firing的拍数；array_drain_cycles=DRAIN推进拍；array_pause_cycles=RUN/DRAIN被冻结的拍数。compute/post overlap仅RUN有效推进且post活动，排空也可能与post重叠但未纳入此旧指标；load/compute overlap同理。不能用RUN单独作脉动阵列容量分母。全部记录独立闭式审计：固定开销=2RC×输出tile数+2×请求tile数+(RC+2)×group数+2MN+1；总周期=固定开销+array_cycles+array_pause+等输入+等输出+psum满等待+post drain。\n\n'
    perf+='理论容量按16/64MAC每推进拍；100MHz仅评估目标，对应1.6/6.4GMAC/s理论值。扩成8×8同时改变PE预算、缓存行数、供数/尾块和RC保存输出开销；必须用同尺寸b4/s4、b8/s8区分拓扑影响。代表性case12为满8×8，case4/13为单行Decode，case14为8×8尾块；case5仅4行，会浪费8×8的行容量。实际资源/时序独立见验证报告，不将理论容量当测得性能。\n\n'
    perf+='本轮保守每tile排空对连续供数明确有成本，更多PE也会增加RC逐槽保存/后处理开销。下一步优先比较group内跨tile连续波前，减少D×tile_count为D×group_count，并继续测输出tile流水/psum保存；在做真实优化前保留广播基线。\n'
    (ROOT/'docs/w4a8_systolic_performance.md').write_text(perf,encoding='utf8')
    brief='# 4×4 / 8×8 脉动原型：内部交流摘要\n\n真正实现相邻PE传递A/B和valid：入口A延迟r、B延迟c，PE(r,c)在注入后r+c推进拍完成对应乘加；全局array_pause冻结skew、链路、acc与读地址。W4A8缓存、group scale与输出合同保留，末token排空后才切bank/保存group。\n\n'
    brief+=f"实际{s['totals']['tasks']}任务/{s['totals']['outputs']}输出/{s['totals']['psums']}组psum与scaled比较通过；4×4/8×8独立数学波前单元通过。\n\n"
    rows=[]
    for cid in (4,5,12):
        for name in ('b4','s4','b8','s8'):
            x=next(x for x in s['simulations'] if x['name']==name);r=record(x,cid,0)
            rows.append([cid,name,r['total_cycles'],r['compute_cycles'],r['array_drain_cycles'],r['input_wait_cycles']])
    brief+=table(['case','配置','连续周期','RUN','排空','等输入'],rows)
    resources=[]
    for e in s['eda']:
        if e['synthesis_completed']:
            u=e['utilization']
            resources.append([e['name'],int(u['LUT']),int(u['FF']),int(u['DSP']),int(u['RAMB36']),int(u['RAMB18']),
                e.get('ooc_timing',{}).get('WNS_ns','未运行/完成'),e.get('ooc_timing',{}).get('WHS_ns','未运行/完成')])
    brief+='\nVU9P临时part、10ns内部评估；资源为实际综合，WNS/WHS仅实际OOC：\n\n'+table(['配置','LUT','FF','DSP','RAMB36','RAMB18','OOC WNS ns','OOC WHS ns'],resources)
    brief+='\n当前瓶颈证据：每tile排空6/14推进拍，保存psum与输出按RC逐槽；因此脉动功能正确不代表此版本更快。4×4/8×8同尺寸广播对照保留，8×8满阵列/Decode/尾块都有实测。EDA完成状态：'+json.dumps([{k:e[k] for k in ('name','synthesis_completed','ooc_completed')} for e in s['eda']])+'。\n\n'
    brief+='下一轮优先group内跨tile连续波前并仅group末排空，然后优化psum/输出tile保存与重叠；Decode仍需N/K专用映射。当前没有真实DDR、完整模型或W4A8 NPU队列适配；VCS未运行。详见架构、验证与性能报告。\n'
    (ROOT/'docs/w4a8_systolic_brief.md').write_text(brief,encoding='utf8')
if __name__=='__main__':main()
