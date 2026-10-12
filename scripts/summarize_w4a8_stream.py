"""Audit incremental wide-input W4A8 implementation and measured ablation results."""
import csv,hashlib,json,re,sys
from pathlib import Path
sys.dont_write_bytecode=True
from summarize import read,utilization,timing
from stream_traffic import traffic
ROOT=Path(__file__).resolve().parents[1]
CONFIGS=[('b8_s1',4,4,8,32,1,8,1),('b1_s0',4,4,8,32,1,1,0),
         ('b1_s1',4,4,8,32,1,1,1),('b8_s0',4,4,8,32,1,8,0),
         ('alt_b8_s1',2,3,5,12,1,8,1),('single_b8_s1',4,4,8,32,0,8,1),
         ('words_b8_s1',4,4,19,32,1,8,1)]
def identity(work):
    saved=json.loads(read(work/'source_inputs.json'))
    for name,digest in saved['files'].items():
        assert hashlib.sha256((ROOT/name).read_bytes()).hexdigest()==digest,name
    return saved
def table(headers,rows):
    return '| '+' | '.join(headers)+' |\n|'+ '|'.join(['---']*len(headers))+'|\n'+''.join('| '+' | '.join(map(str,r))+' |\n' for r in rows)
def main():
    summary={'scope':'Wide ingress and group-end-only scale; no DDR','simulations':[]}
    for name,rows,cols,tk,group,db,bus,once in CONFIGS:
        work=ROOT/f'build/sim_w4a8_stream_{name}'
        identity(work)
        assert (work/'vectors.txt').read_bytes()==(ROOT/f'build/w4a8_vectors/group{group}.txt').read_bytes()
        model=json.loads(read(ROOT/f'build/w4a8_vectors/group{group}.json'))
        log=read(work/'run.log')
        assert read(work/'PASS.txt').strip()=='PASS' and not re.search(r'Fatal:|FAILED|TIMEOUT|^ERROR:',log,re.M)
        mt=re.search(r'W4A8_STREAM_TESTS_PASS rows=(\d+) cols=(\d+) tile=(\d+) group=(\d+) db=(\d+) tasks=(\d+) outputs=(\d+) psums=(\d+) checks=(\d+) overlap=(\d+) held_inputs=(\d+) bytes=(\d+) scale_once=(\d+)',log)
        assert mt and tuple(map(int,mt.group(1,2,3,4,5,12,13)))==(rows,cols,tk,group,db,bus,once)
        records=[{k:int(v) for k,v in r.items()} for r in csv.DictReader((work/'results.csv').open(encoding='utf-8-sig'))]
        expected=[(i,0,j) for i in range(12) for j in range(3)]
        expected[33:33]=[(10,1,2),(10,1,0)]
        assert len(records)==38 and int(mt[6])==38 and int(mt[7])==621
        cases=model['cases']
        assert int(mt[8])==3*sum(c['m']*c['n']*c['groups'] for c in cases)+2*cases[10]['m']*cases[10]['n']*cases[10]['groups']
        for r,(cid,rec,mode) in zip(records,expected):
            assert (r['case_id'],r['recovery'],r['mode'])==(cid,rec,mode)
            c=cases[cid]
            assert (r['M'],r['N'],r['K'])==(c['m'],c['n'],c['k'])
            assert tuple(r[k] for k in ('ROWS','COLS','TILE_K','GROUP_SIZE','DOUBLE_BUFFER','BUS_BYTES','SCALE_ONCE'))==(rows,cols,tk,group,db,bus,once)
            pred=traffic(c['m'],c['n'],c['k'],rows,cols,tk,group,bus,once)
            for key,value in pred.items():
                if key!='tiles':assert r[key]==value,(name,cid,key,r[key],value)
            assert r['compute_cycles']+r['input_wait_cycles']+r['output_wait_cycles']<=r['total_cycles']
            assert 0<=r['overlap_cycles']<=r['compute_cycles']
            assert r['padding_bytes']+r['weight_bytes']+r['activation_bytes']+r['scale_bytes']==r['input_beats']*bus
            if not db:assert r['overlap_cycles']==0
        assert int(mt[11])>0
        if db:assert int(mt[10])>0
        summary['simulations'].append(dict(name=name,ROWS=rows,COLS=cols,TILE_K=tk,GROUP_SIZE=group,DOUBLE_BUFFER=db,BUS_BYTES=bus,SCALE_ONCE=once,tasks=38,outputs=621,psums=int(mt[8]),checks=int(mt[9]),cycles=records))
    old=ROOT/'build/sim_w4a8_4x4_k8_g32_db'
    identity(old)
    old_records=[{k:int(v) for k,v in r.items()} for r in csv.DictReader((old/'results.csv').open(encoding='utf-8-sig'))]
    narrow=next(s for s in summary['simulations'] if s['name']=='b1_s0')
    for new,previous in zip(narrow['cycles'],old_records):
        if new['mode'] in (0,1):
            assert all(new[k]==v for k,v in previous.items()),('legacy timing mismatch',new,previous)
    summary['legacy_mode0_mode1_match']=True
    summary['totals']={key:sum(s[key] for s in summary['simulations']) for key in ('tasks','outputs','psums','checks')}
    summary['synthesis']={'completed':False};summary['ooc']={'completed':False}
    synth=ROOT/'build/synth_w4a8_stream'
    if (synth/'primitive_counts.txt').exists():
        identity(synth);log=read(synth/'synth_w4a8_stream.log')
        assert re.search(r'^W4A8_STREAM_SYNTHESIS_PASS',log,re.M) and not re.search(r'^ERROR:',log,re.M)
        pc=read(synth/'primitive_counts.txt')
        assert 'Latch_count=0' in pc and 'Blackbox_count=0' in pc
        summary['synthesis']=dict(completed=True,part=re.search(r'^Part=(\S+)',pc,re.M)[1],
            utilization=utilization(synth/'utilization_synth.rpt'),timing=timing(synth/'timing_synth.rpt'),
            warnings=[line for line in log.splitlines() if line.startswith(('WARNING:','CRITICAL WARNING:'))])
        assert summary['synthesis']['part']=='xcvu9p-flga2104-2L-e'
        for key in ('no_clock','unconstrained_internal_endpoints','latch_loops'):
            assert summary['synthesis']['timing']['checks'][key]==0
        if re.search(r'^W4A8_STREAM_OOC_FINISHED',log,re.M):
            route=read(synth/'route_status_ooc.rpt');drc=read(synth/'drc_ooc.rpt')
            rc={key:int(re.search(r'# of '+label+r'\.+\s*:\s*(\d+)',route)[1]) for key,label in [
                ('routable_nets','routable nets'),('fully_routed_nets','fully routed nets'),
                ('routing_errors','nets with routing errors'),('explicit_gaps','nets with explicit gaps')]}
            summary['ooc']=dict(completed=True,utilization=utilization(synth/'utilization_ooc.rpt'),
                timing=timing(synth/'timing_ooc.rpt'),route_status=rc,
                design_state=re.search(r'\| Design State\s*:\s*([^\r\n]+)',drc)[1].strip(),
                drc=[dict(rule=r,severity=se,description=ds.strip(),checks=int(ct)) for r,se,ds,ct in re.findall(r'^\|\s*([A-Z][A-Z0-9_-]+)\s*\|\s*(Warning|Error|Critical Warning)\s*\|\s*([^|]+)\s*\|\s*(\d+)\s*\|',drc,re.M)])
            assert rc['routing_errors']==0
    neg=ROOT/'build/sim_w4a8_stream_b8_s1_negative';summary['negative_probe']={'executed':False}
    if (neg/'observed_exit_code.txt').exists():
        identity(neg);code=int(read(neg/'observed_exit_code.txt'))
        assert code!=0 and 'W4A8_STREAM_CHECK_FAILED' in read(neg/'run.log') and not (neg/'PASS.txt').exists()
        summary['negative_probe']=dict(executed=True,exit_code=code)
    (ROOT/'build/w4a8_stream_summary.json').write_text(json.dumps(summary,ensure_ascii=False,indent=2)+'\n',encoding='utf8')
    report(summary)
    print('W4A8_STREAM_ARTIFACT_AUDIT_PASS '+json.dumps(summary['totals']))
    print(json.dumps({'synthesis':{k:v for k,v in summary['synthesis'].items() if k!='warnings'},'ooc':summary['ooc']},indent=2))

def report(s):
    text='# W4A8 宽供数优化：实际验证与性能\n\n'
    text+='本轮新增 w4a8_stream，阶段二 w4a8_linear 及其报告/源码保持原样。数值合同、量化向量和参考输出未改变，参考模型的A/B/C误差仍见 w4a8_validation.md。工具为Windows PowerShell5.1、Python3.13.5、Vivado/XSim2025.2 Build6299465，评估part仍为xcvu9p-flga2104-2L-e，未确认板卡。\n\n'
    text+='## 实际自检\n\n'
    text+=table(['配置','BUS_BYTES','SCALE_ONCE','阵列/Ktile/group','任务','输出','group psum','检查'],[[x['name'],x['BUS_BYTES'],x['SCALE_ONCE'],f"{x['ROWS']}×{x['COLS']}/{x['TILE_K']}/{x['GROUP_SIZE']}",x['tasks'],x['outputs'],x['psums'],x['checks']] for x in s['simulations']])
    text+='\n每配置36正常任务+2复位恢复任务，全部输出及group psum与原位精确参考一致；覆盖全部INT4编码、M/N/K尾块、不同scale、跨tile group、末组、连续任务、忙start、输入持稳、req_scale/keep持稳、输出背压、运行中/输出阻塞时reset。输入无效字节填0xA5，逐拍检查keep，验证尾部padding不污染结果。tile19配置让A/B RAM超过一个字，验证不同字地址、字内选择及奇K起点。\n\n'
    text+='BUS_BYTES=1/SCALE_ONCE=0与阶段二模式0/1的所有已有CSV计数和周期完全一致，提供供数优化的回归对照。随机模型的握手时间线随配置不同，不作逐拍公平对照。故障注入：'+json.dumps(s['negative_probe'])+'。任务/全局超时仍为200000周期/20ms，脚本检查fatal和PASS，失败非零退出。\n\n'
    text+='## 供数条件与指标\n\n模式0每拍最多一个beat，无额外首延迟；模式1每包首延迟5，每8物理字节额外暂停4拍，并按BUS_BYTES插入BUS_BYTES-1拍间隔，以保持各宽度的名义物理带宽预算相同，padding也占预算；模式2首延迟5、固定LFSR种子随机暂停、DUT load_pause及输出背压。没有真实DDR性能含义。bytes计数只计keep=1的有效字节，input_beats计所有接受beat，padding_bytes=beats×BUS_BYTES−有效字节。compute/input_wait/output_wait互斥，overlap为compute子集，不可重复加总。\n\n'
    rows=[]
    for sim in s['simulations']:
        for r in sim['cycles']:
            if r['case_id'] not in (4,5) or r['recovery']:continue
            rows.append([sim['name'],'Decode' if r['case_id']==4 else 'Prefill',r['mode'],r['total_cycles'],r['weight_bytes'],r['activation_bytes'],r['scale_bytes'],r['input_beats'],r['padding_bytes'],r['compute_cycles'],r['input_wait_cycles'],r['output_wait_cycles'],r['overlap_cycles'],f"{100*r['valid_macs']/(r['ROWS']*r['COLS']*r['total_cycles']):.2f}%"])
    text+=table(['配置','任务','模式','总周期','W字节','A字节','scale字节','beat','padding字节','RUN','等输入','等输出','重叠','端到端MAC利用率'],rows)
    text+='\nDecode=1×13×96、Prefill=4×12×96。利用率分母为硬件ROWS×COLS×总周期；有效MAC排除零填充。理论峰值默认16MAC/拍，100MHz目标下1.6GMAC/s，并非实测板上吞吐。\n\n'
    text+='## 消融对照：连续供数\n\n'
    rows=[]
    base=next(x for x in s['simulations'] if x['name']=='b1_s0')
    for cid in (4,5):
        b=next(r for r in base['cycles'] if (r['case_id'],r['mode'],r['recovery'])==(cid,0,0))
        for name in ('b1_s0','b1_s1','b8_s0','b8_s1'):
            sim=next(x for x in s['simulations'] if x['name']==name)
            r=next(r for r in sim['cycles'] if (r['case_id'],r['mode'],r['recovery'])==(cid,0,0))
            rows.append(['Decode' if cid==4 else 'Prefill',name,r['total_cycles'],f"{100*(1-r['total_cycles']/b['total_cycles']):.2f}%",r['scale_bytes'],r['padding_bytes']])
    text+=table(['任务','配置','周期','相对字节基线周期减少','scale有效字节','padding字节'],rows)
    text+='\n扩大输入口并不保证在相同物理带宽下改善：每权重列按word对齐，tile8每列4权重字节占8字节beat；模式1如出现退化，应先解决packing/复用，而非将其隐藏。A跨N tile复用尚未实现，仍重复传输；scale仅每M/N输出tile每group一次，尚未跨N/M tile复用。\n\n'
    text+='## 综合/内部时序\n\n'
    if s['synthesis']['completed']:
        sy=s['synthesis'];u=sy['utilization'];rows=[['综合',*[u.get(k,'—') for k in ('LUT','FF','DSP','RAMB18','RAMB36','LUTRAM','URAM')],sy['timing']['WNS_ns'],sy['timing']['WHS_ns']]]
        if s['ooc']['completed']:
            oc=s['ooc'];u=oc['utilization'];rows.append(['OOC',*[u.get(k,'—') for k in ('LUT','FF','DSP','RAMB18','RAMB36','LUTRAM','URAM')],oc['timing']['WNS_ns'],oc['timing']['WHS_ns']])
        text+=table(['阶段','LUT','FF','DSP','RAMB18','RAMB36','LUTRAM','URAM','WNS ns','WHS ns'],rows)
        text+='\nLatch=0、blackbox=0。实际存储映射看build/synth_w4a8_stream/ram_synth.rpt；默认宽字depth1实际映射为FF，LUTRAM=0，group/output仍为RAMB18/RAMB36；对应资源代价应计入评估，不能仅因distributed属性就宣称LUTRAM。完整DSP实例见dsp_mapping.txt。10ns评估约束，虚拟BUFGCE_X0Y0；无板级管脚/I/O延迟，综合估计不代表布线后频率，OOC仅内部时序。\n\n'
        text+='时序检查及OOC边界：\n\n~~~json\n'+json.dumps({'synthesis_timing':sy['timing'],'ooc':s['ooc']},indent=2,ensure_ascii=False)+'\n~~~\n\n'
        text+='实际关键警告见synth_w4a8_stream.log（本汇总记录全部WARNING/CRITICAL WARNING）：\n\n~~~text\n'+'\n'.join(sy['warnings'])+'\n~~~\n\n'
    else:text+='本轮综合未运行/完成，不能引用阶段二资源冒充新顶层。\n\n'
    text+='## 状态与下一步\n\n已实现并验证：报告中七组配置及协议、数值、流量。已实现但未验证：其他BUS_BYTES/尺寸组合、最大64×64×4096任务、VCS编译执行。未来：A/weight跨输出tile复用、更高效跨lane packing、psum/scale流水解耦、新顶层接入NPU任务队列、真实DDR/DMA。未实现zero-point/AWQ/bias/INT8 requant/完整Transformer。\n\n'
    text+='下一步优先依据模式1的padding成本与模式0剩余scale开销，比较跨列packed写入（每bank仍一写）、更长K tile和A复用；随后解耦scale流水；Decode仍只有一个有效行，需要单独评估N/K并行映射。VCS编译执行未运行，新增 scripts/run_w4a8_stream_vcs.sh 可配置入口；bash -n实际退出0，不能代表VCS通过。原始CSV/命令/源哈希在build/sim_w4a8_stream_*，汇总在build/w4a8_stream_summary.json。\n'
    (ROOT/'docs/w4a8_stream_validation.md').write_text(text,encoding='utf8')
    brief='# 宽供数 W4A8：内部交流摘要\n\n'
    brief+='本轮在原位精确W4A8通路上加入64bit beat/keep和组末一次scale加载，保留原顶层、数值合同及双缓冲所有权协议。原NPU任务队列仍未连接新顶层，真实DDR/DMA仍未实现。\n\n'
    brief+=f"七配置已通过：{s['totals']['tasks']}任务、{s['totals']['outputs']}输出、{s['totals']['psums']}group psum。包括字节/宽口、scale开关、单/双缓冲、group12备用阵列及tile19多word地址。输入padding填0xA5，尾掩码、暂停持稳、复位恢复、输出背压和流量均自检。\n\n"
    rows=[]
    for cid in (4,5):
        for name in ('b1_s0','b1_s1','b8_s0','b8_s1'):
            sim=next(x for x in s['simulations'] if x['name']==name)
            r=next(r for r in sim['cycles'] if (r['case_id'],r['mode'],r['recovery'])==(cid,0,0))
            limited=next(r for r in sim['cycles'] if (r['case_id'],r['mode'],r['recovery'])==(cid,1,0))
            rows.append(['Decode' if cid==4 else 'Prefill',name,r['total_cycles'],limited['total_cycles'],r['scale_bytes'],r['input_beats'],r['padding_bytes']])
    brief+=table(['任务','配置','连续周期','同物理带宽预算周期','scale字节','beat','padding字节'],rows)
    brief+='\n代表性Prefill：36个K tile请求，27个非组末请求各8个beat、9个组末各10个beat，共306beat；W576+A1152+scale144有效字节，padding576，物理字节2448。源先装完整bank，再与另bank计算重叠。计算、group保存和scale时序未改变。\n\n'
    if s['synthesis']['completed']:
        sy=s['synthesis'];u=sy['utilization']
        brief+=f"VU9P临时评估part综合：{int(u['LUT'])} LUT、{int(u['FF'])} FF、{int(u['DSP'])} DSP、{int(u['RAMB18'])} RAMB18、{int(u['RAMB36'])} RAMB36、{int(u['LUTRAM'])} LUTRAM、0URAM、0latch。默认宽RAM深度1，实际映射FF；较原字节口增加了寄存器及选择逻辑。\n\n"
        if s['ooc']['completed']:
            oc=s['ooc'];brief+=f"OOC内部10ns约束 WNS {oc['timing']['WNS_ns']:+.3f}ns、WHS {oc['timing']['WHS_ns']:+.3f}ns；路由/DRC限制见验证报告。没有板级管脚/接口延迟，不能承诺板上频率。\n\n"
        else:brief+='OOC未运行或未完成。\n\n'
    else:brief+='新顶层综合未运行或未完成。\n\n'
    brief+='结论与讨论：连续供数Prefill等待输入从1417降到9拍，瓶颈转向group保存/scale与控制：1147总周期中，RUN288、WAIT9，其余850。576拍用于9group的保存/scale。等物理带宽预算下，64bit/scale-once的Decode比原byte慢，Prefill仅略有改善；优先解决跨列packing/padding及A复用，再解耦psum/scale流水。Decode空行利用率问题仍需独立映射实验。上述为指定仿真模型结果，不代表DDR/板上性能。\n'
    (ROOT/'docs/w4a8_stream_brief.md').write_text(brief,encoding='utf8')
if __name__=='__main__':main()
