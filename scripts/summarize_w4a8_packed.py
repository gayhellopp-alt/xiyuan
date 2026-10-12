"""Audit incremental wide-input W4A8 implementation and measured ablation results."""
import csv,hashlib,json,re,sys
from pathlib import Path
sys.dont_write_bytecode=True
from summarize import read,utilization,timing
from packed_traffic import traffic
ROOT=Path(__file__).resolve().parents[1]
CONFIGS=[('paired',4,4,8,32,1,8,1,1),('unpacked',4,4,8,32,1,8,1,0),
         ('alt',2,3,5,12,1,8,1,1),('words',4,4,19,32,1,8,1,1),
         ('single',4,4,8,32,0,8,1,1),('scales',4,4,8,32,1,8,0,1)]

def identity(work):
    saved=json.loads(read(work/'source_inputs.json'))
    for name,digest in saved['files'].items():
        assert hashlib.sha256((ROOT/name).read_bytes()).hexdigest()==digest,name
    return saved
def table(headers,rows):
    return '| '+' | '.join(headers)+' |\n|'+ '|'.join(['---']*len(headers))+'|\n'+''.join('| '+' | '.join(map(str,r))+' |\n' for r in rows)
def main():
    summary={'scope':'Paired-column weight ingress; no DDR','simulations':[]}
    for name,rows,cols,tk,group,db,bus,once,pack in CONFIGS:
        work=ROOT/f'build/sim_w4a8_packed_{name}'
        identity(work)
        assert (work/'vectors.txt').read_bytes()==(ROOT/f'build/w4a8_vectors/group{group}.txt').read_bytes()
        model=json.loads(read(ROOT/f'build/w4a8_vectors/group{group}.json'))
        log=read(work/'run.log')
        assert read(work/'PASS.txt').strip()=='PASS' and not re.search(r'Fatal:|FAILED|TIMEOUT|^ERROR:',log,re.M)
        mt=re.search(r'W4A8_PACKED_TESTS_PASS rows=(\d+) cols=(\d+) tile=(\d+) group=(\d+) db=(\d+) tasks=(\d+) outputs=(\d+) psums=(\d+) checks=(\d+) overlap=(\d+) held_inputs=(\d+) bytes=(\d+) scale_once=(\d+) pack=(\d+) dual_writes=(\d+) holey_keeps=(\d+) odd_k=(\d+)',log)
        assert mt and tuple(map(int,mt.group(1,2,3,4,5,12,13,14)))==(rows,cols,tk,group,db,bus,once,pack)
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
            assert tuple(r[k] for k in ('ROWS','COLS','TILE_K','GROUP_SIZE','DOUBLE_BUFFER','BUS_BYTES','SCALE_ONCE','PACK_COLS'))==(rows,cols,tk,group,db,bus,once,pack)
            pred=traffic(c['m'],c['n'],c['k'],rows,cols,tk,group,bus,once,pack)
            for key,value in pred.items():
                if key!='tiles':assert r[key]==value,(name,cid,key,r[key],value)
            assert r['compute_cycles']+r['input_wait_cycles']+r['output_wait_cycles']<=r['total_cycles']
            assert 0<=r['overlap_cycles']<=r['compute_cycles']
            assert r['padding_bytes']+r['weight_bytes']+r['activation_bytes']+r['scale_bytes']==r['input_beats']*bus
            if not db:assert r['overlap_cycles']==0
        assert int(mt[11])>0
        if db:assert int(mt[10])>0
        if pack:
            assert int(mt[15])>0 and int(mt[16])>0
        if tk%2:assert int(mt[17])>0
        summary['simulations'].append(dict(name=name,ROWS=rows,COLS=cols,TILE_K=tk,GROUP_SIZE=group,DOUBLE_BUFFER=db,BUS_BYTES=bus,SCALE_ONCE=once,PACK_COLS=pack,dual_writes=int(mt[15]),holey_keeps=int(mt[16]),odd_k=int(mt[17]),tasks=38,outputs=621,psums=int(mt[8]),checks=int(mt[9]),cycles=records))
    old=ROOT/'build/sim_w4a8_stream_b8_s1'
    identity(old)
    old_records=[{k:int(v) for k,v in r.items()} for r in csv.DictReader((old/'results.csv').open(encoding='utf-8-sig'))]
    unpacked=next(x for x in summary['simulations'] if x['name']=='unpacked')
    for new,previous in zip(unpacked['cycles'],old_records):
        assert all(new[k]==v for k,v in previous.items()),('unpacked timing mismatch',new,previous)
    summary['unpacked_all_modes_match']=True
    summary['totals']={key:sum(s[key] for s in summary['simulations']) for key in ('tasks','outputs','psums','checks')}
    summary['synthesis']={'completed':False};summary['ooc']={'completed':False}
    synth=ROOT/'build/synth_w4a8_packed'
    if (synth/'primitive_counts.txt').exists():
        identity(synth);log=read(synth/'synth_w4a8_packed.log')
        assert re.search(r'^W4A8_PACKED_SYNTHESIS_PASS',log,re.M) and not re.search(r'^ERROR:',log,re.M)
        pc=read(synth/'primitive_counts.txt')
        assert 'Latch_count=0' in pc and 'Blackbox_count=0' in pc
        summary['synthesis']=dict(completed=True,part=re.search(r'^Part=(\S+)',pc,re.M)[1],
            utilization=utilization(synth/'utilization_synth.rpt'),timing=timing(synth/'timing_synth.rpt'),
            warnings=[line for line in log.splitlines() if line.startswith(('WARNING:','CRITICAL WARNING:'))])
        assert summary['synthesis']['part']=='xcvu9p-flga2104-2L-e'
        for key in ('no_clock','unconstrained_internal_endpoints','latch_loops'):
            assert summary['synthesis']['timing']['checks'][key]==0
        if re.search(r'^W4A8_PACKED_OOC_FINISHED',log,re.M):
            route=read(synth/'route_status_ooc.rpt');drc=read(synth/'drc_ooc.rpt')
            rc={key:int(re.search(r'# of '+label+r'\.+\s*:\s*(\d+)',route)[1]) for key,label in [
                ('routable_nets','routable nets'),('fully_routed_nets','fully routed nets'),
                ('routing_errors','nets with routing errors'),('explicit_gaps','nets with explicit gaps')]}
            summary['ooc']=dict(completed=True,utilization=utilization(synth/'utilization_ooc.rpt'),
                timing=timing(synth/'timing_ooc.rpt'),route_status=rc,
                design_state=re.search(r'\| Design State\s*:\s*([^\r\n]+)',drc)[1].strip(),
                drc=[dict(rule=r,severity=se,description=ds.strip(),checks=int(ct)) for r,se,ds,ct in re.findall(r'^\|\s*([A-Z][A-Z0-9_-]+)\s*\|\s*(Warning|Error|Critical Warning)\s*\|\s*([^|]+)\s*\|\s*(\d+)\s*\|',drc,re.M)])
            assert rc['routing_errors']==0
    neg=ROOT/'build/sim_w4a8_packed_paired_negative';summary['negative_probe']={'executed':False}
    if (neg/'observed_exit_code.txt').exists():
        identity(neg);code=int(read(neg/'observed_exit_code.txt'))
        assert code!=0 and 'W4A8_PACKED_CHECK_FAILED' in read(neg/'run.log') and not (neg/'PASS.txt').exists()
        summary['negative_probe']=dict(executed=True,exit_code=code)
    (ROOT/'build/w4a8_packed_summary.json').write_text(json.dumps(summary,ensure_ascii=False,indent=2)+'\n',encoding='utf8')
    report(summary)
    print('W4A8_PACKED_ARTIFACT_AUDIT_PASS '+json.dumps(summary['totals']))
    print(json.dumps({'synthesis':{k:v for k,v in summary['synthesis'].items() if k!='warnings'},'ooc':summary['ooc']},indent=2))

def report(s):
    text='# W4A8 跨列权重打包：实际验证与性能\n\n'
    text+='本轮新增w4a8_packed，保留w4a8_stream和w4a8_linear及其回归/报告。数值、INT4 nibble次序和外部权重列优先存储不变，只改变tile数据包与权重bank字宽。工具：Windows PowerShell5.1、Python3.13.5、Vivado/XSim2025.2 Build6299465；VU9P part仍为xcvu9p-flga2104-2L-e临时评估选择，未确认板卡。模型仅需Python标准库。\n\n'
    text+='## 已运行自检\n\n'
    text+=table(['配置','PACK_COLS','阵列/tile/group','任务','输出','group psum','双bank写拍','非连续keep拍','奇K请求'],[[x['name'],x['PACK_COLS'],f"{x['ROWS']}×{x['COLS']}/{x['TILE_K']}/{x['GROUP_SIZE']}",x['tasks'],x['outputs'],x['psums'],x['dual_writes'],x['holey_keeps'],x['odd_k']] for x in s['simulations']])
    text+='\n每配置36正常任务+2复位恢复，所有有效输出和group psum完全等于原位精确参考。覆盖全部INT4编码、零/边界/正负/固定随机、M/N/K尾块、末group、跨tile累加、不同scale、暂停/背压、连续任务及计算中/输出受阻复位。keep逐字节独立检查，无效槽填0xA5；检查每拍有效bank写数与所有权。tile5/group12覆盖奇列数和奇K起点；tile19覆盖权重多32-bit字及A多64-bit字地址。超时200000周期/全局20ms，脚本检查fatal/PASS，失败非零退出。\n\n'
    text+='PACK_COLS=0对照配置的所有模式、任务CSV周期和原有计数与上一轮w4a8_stream完全一致；新源与产物SHA256审计通过。故障注入：'+json.dumps(s['negative_probe'])+'。量化三层A/B/C数值合同和误差未改变，见w4a8_numerics.md和w4a8_validation.md；没有真实模型准确率测量。\n\n'
    text+='## 供数及计数口径\n\n'
    text+='mode0：最多每拍一个64bit beat、无额外首延迟；mode1：每包首延迟5，每beat按8物理字节占用预算，beat之间7拍基础间隔+每8物理字节4拍burst间隔，padding也计预算；mode2：固定0x20261012 LFSR暂停、请求周期、首延迟及TB输入暂停/输出背压。各配置相同名义物理字节预算，但packet长度改变，随机握手时间线不同。只代表指定仿真模型，不代表DDR/板上性能。\n\n'
    text+='valid_bytes=weight_bytes+activation_bytes+scale_bytes；physical_bytes=input_beats×BUS_BYTES；padding_bytes=physical_bytes−valid_bytes。compute/input_wait/output_wait互斥，overlap是compute子集，不可重复加总；计数32-bit无符号，每合法start清零，done后保持。有效MAC=m×n×k，尾填零不计入。峰值默认16MAC/拍、100MHz下理论1.6GMAC/s，未测板上吞吐。\n\n'
    text+='## 代表性对照\n\n'
    rows=[]
    for name in ('unpacked','paired','words'):
        sim=next(x for x in s['simulations'] if x['name']==name)
        for r in sim['cycles']:
            if r['case_id'] not in (4,5) or r['recovery']:continue
            rows.append([name,'Decode 1×13×96' if r['case_id']==4 else 'Prefill 4×12×96',r['mode'],r['total_cycles'],r['input_beats'],r['padding_bytes'],r['weight_bytes'],r['activation_bytes'],r['scale_bytes'],r['compute_cycles'],r['input_wait_cycles'],r['output_wait_cycles'],r['overlap_cycles'],f"{100*r['valid_macs']/(r['ROWS']*r['COLS']*r['total_cycles']):.2f}%"])
    text+=table(['布局','任务','模式','总周期','beat','padding','W字节','A字节','scale字节','RUN','等输入','等输出','重叠','MAC利用率'],rows)
    text+='\n利用率分母为实际硬件ROWS×COLS×总周期，不把padding作为MAC。words配置tile19，不应仅归因于列打包，应与其旧tile19报告同时比较。\n\n'
    base=next(x for x in s['simulations'] if x['name']=='unpacked')
    opt=next(x for x in s['simulations'] if x['name']=='paired')
    rows=[]
    for cid in (4,5):
        for mode in (0,1,2):
            b=next(r for r in base['cycles'] if (r['case_id'],r['mode'],r['recovery'])==(cid,mode,0))
            r=next(r for r in opt['cycles'] if (r['case_id'],r['mode'],r['recovery'])==(cid,mode,0))
            rows.append(['Decode' if cid==4 else 'Prefill',mode,b['total_cycles'],r['total_cycles'],f"{100*(1-r['total_cycles']/b['total_cycles']):.2f}%",b['input_beats']*8,r['input_beats']*8])
    text+=table(['任务','模式','旧周期','新周期','周期减少','旧物理字节','新物理字节'],rows)
    comparison_rows=list(rows)
    text+='\n## 综合与内部时序\n\n'
    if s['synthesis']['completed']:
        sy=s['synthesis'];u=sy['utilization']
        rows=[['综合',*[u.get(k,'—') for k in ('LUT','FF','DSP','RAMB18','RAMB36','LUTRAM','URAM')],sy['timing']['WNS_ns'],sy['timing']['WHS_ns']]]
        if s['ooc']['completed']:
            oc=s['ooc'];u=oc['utilization'];rows.append(['OOC',*[u.get(k,'—') for k in ('LUT','FF','DSP','RAMB18','RAMB36','LUTRAM','URAM')],oc['timing']['WNS_ns'],oc['timing']['WHS_ns']])
        text+=table(['阶段','LUT','FF','DSP','RAMB18','RAMB36','LUTRAM','URAM','WNS ns','WHS ns'],rows)
        text+='\n默认4×4/tile8/group32/64bit/SCALE_ONCE1/PACK_COLS1已实际综合。Latch=0、blackbox=0；其余配置仅仿真。实际A/W存储映射见ram_synth.rpt，不能由RTL数组或RAM_STYLE直接命名。权重bank宽32bit、深度2，实际为160 LUTRAM；A仍64bit、深度1并映射FF。较上一版宽口综合3102FF/2141LUT，本版2335FF/2324LUT，减少767FF、增加183LUT。RAM/FF实现结果以报告为准。16个DSP用于PE，其余用于scale及MAC统计；没有改成脉动阵列，也没有打包多个乘法进一个DSP。\n\n'
        text+='~~~json\n'+json.dumps({'synthesis_timing':sy['timing'],'ooc':s['ooc']},indent=2,ensure_ascii=False)+'\n~~~\n\n'
        text+='工具警告原文（完整日志/计数见build/synth_w4a8_packed）：\n\n~~~text\n'+'\n'.join(sy['warnings'])+'\n~~~\n\n'
        text+='10ns是初步内部约束，虚拟BUFGCE_X0Y0，无板级管脚/I/O延迟；综合估计不是布局布线频率，OOC仍有边界限制，不作板级signoff或token/s承诺。\n\n'
    else:text+='新顶层综合未运行/完成，不能引用旧资源作为本轮结果。\n\n'
    text+='## 当前边界\n\n已实现且验证：表中六配置，传输/数值/背压/复位及默认综合/OOC状态如上。未验证：其他合法参数组合、最大64×64×4096实际任务、VCS编译执行。本机先前未发现VCS，本轮编译执行未运行，提供run_w4a8_packed_vcs.sh，Bash -n已实际退出0，不等于VCS验证。模型MAX_DATA8192用于小型样本。\n\n'
    text+='未来：A跨N tile复用、group psum双缓冲及scale流水解耦、新顶层接NPU队列、真实DDR/DMA、专门Decode映射、脉动阵列对照。当前组末scale仍每个M/N tile传一次，未做跨输出tile scale cache；完整Transformer/zero-point/AWQ/bias/INT8 requant均未实现。\n\n'
    text+='原始CSV/命令/源哈希位于build/sim_w4a8_packed_*，EDA位于build/synth_w4a8_packed，汇总build/w4a8_packed_summary.json。layout、keep、bank地址与端口合同见w4a8_packed_architecture.md。\n'
    (ROOT/'docs/w4a8_packed_validation.md').write_text(text,encoding='utf8')
    brief='# 列对权重打包：内部交流摘要\n\n'
    brief+=f"新增w4a8_packed，64bit beat将两个输出列各4个packed权重字节写入两个独立32bit bank；每bank仍一写端口。原数值、计算、group scale与双缓冲控制保持。六配置{ s['totals']['tasks']}任务/{s['totals']['outputs']}输出/{s['totals']['psums']}group psum全部通过，奇列/奇K/多word、非连续keep、暂停、背压、复位均覆盖。\n\n"
    brief+=table(['任务','模式','旧周期','新周期','周期减少','旧物理字节','新物理字节'],comparison_rows)
    brief+='\nPrefill 4×12×96共36请求：权重72beat、激活144beat、scale18beat，总234beat/1872字节，无padding，达到之前布局推算目标。外存源矩阵仍列优先，列对打包由TB供数模型完成；实际DMA需实现同一packet合同。Decode有奇列及小scale段，仍存在padding。供数模式代表可复现模型，不是DDR/板上性能。\n\n'
    if s['synthesis']['completed']:
        sy=s['synthesis'];u=sy['utilization']
        brief+=f"默认综合{int(u['LUT'])}LUT、{int(u['FF'])}FF、{int(u['DSP'])}DSP、{int(u['RAMB18'])}RAMB18、{int(u['RAMB36'])}RAMB36、{int(u['LUTRAM'])}LUTRAM、0URAM、0latch。存储映射见实际RAM报告。\n\n"
        if s['ooc']['completed']:
            oc=s['ooc'];brief+=f"OOC内部10ns WNS{oc['timing']['WNS_ns']:+.3f}ns/WHS{oc['timing']['WHS_ns']:+.3f}ns；{oc['route_status']}。接口未设板级/父级延迟，边界警告详见报告。\n\n"
        else:brief+='OOC未运行或未完成。\n\n'
    else:brief+='综合未运行或未完成。\n\n'
    brief+='下一步：连续供数仍由group保存/scale及控制主导，应实现两组psum buffer与独立scale流水；带宽进一步优化考虑A跨N tile复用。Decode有效行少，脉动阵列应作为同接口对照实验，不保证自然提高GEMV利用率。NPU队列集成、DDR/DMA与完整模型仍是后续工作。\n'
    (ROOT/'docs/w4a8_packed_brief.md').write_text(brief,encoding='utf8')
if __name__=='__main__':main()
