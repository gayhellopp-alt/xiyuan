"""Audit incremental wide-input W4A8 implementation and measured ablation results."""
import csv,hashlib,json,re,sys
from pathlib import Path
sys.dont_write_bytecode=True
from summarize import read,utilization,timing
from reuse_traffic import traffic
ROOT=Path(__file__).resolve().parents[1]
CONFIGS=[('reuse',4,4,8,32,1,8,1),('no_reuse',4,4,8,32,1,8,0),
         ('alt',2,3,5,12,1,8,1),('words',4,4,19,32,1,8,1),
         ('single',4,4,8,32,0,8,1),('one',1,1,8,32,1,8,1),('byte',4,4,8,32,1,1,1)]

def identity(work):
    saved=json.loads(read(work/'source_inputs.json'))
    for name,digest in saved['files'].items():
        assert hashlib.sha256((ROOT/name).read_bytes()).hexdigest()==digest,name
    return saved
def table(headers,rows):
    return '| '+' | '.join(headers)+' |\n|'+ '|'.join(['---']*len(headers))+'|\n'+''.join('| '+' | '.join(map(str,r))+' |\n' for r in rows)
def main():
    summary={'scope':'Per-row full-K activation cache reused across N tiles; no DDR','simulations':[]}
    for name,rows,cols,tk,group,db,bus,reuse in CONFIGS:
        once=1;pack=1;overlap=1;pipeline=1
        work=ROOT/f'build/sim_w4a8_reuse_{name}'
        identity(work)
        assert (work/'vectors.txt').read_bytes()==(ROOT/f'build/w4a8_vectors/group{group}.txt').read_bytes()
        model=json.loads(read(ROOT/f'build/w4a8_vectors/group{group}.json'))
        log=read(work/'run.log')
        assert read(work/'PASS.txt').strip()=='PASS' and not re.search(r'Fatal:|FAILED|TIMEOUT|^ERROR:',log,re.M)
        mt=re.search(r'W4A8_REUSE_TESTS_PASS rows=(\d+) cols=(\d+) tile=(\d+) group=(\d+) db=(\d+) tasks=(\d+) outputs=(\d+) psums=(\d+) checks=(\d+) overlap=(\d+) held_inputs=(\d+) bytes=(\d+) scale_once=(\d+) pack=(\d+) dual_writes=(\d+) holey_keeps=(\d+) odd_k=(\d+) post_overlap=(\d+) pipeline=(\d+) scaled=(\d+) full_queue=(\d+) held_pipe=(\d+) post_resets=(\d+) a_reuse=(\d+) cache_hits=(\d+) cache_writes=(\d+) cache_switches=(\d+)',log)
        assert mt and tuple(map(int,mt.group(1,2,3,4,5,12,13,14,18,19,24)))==(rows,cols,tk,group,db,bus,once,pack,overlap,pipeline,reuse)
        records=[{k:int(v) for k,v in r.items()} for r in csv.DictReader((work/'results.csv').open(encoding='utf-8-sig'))]
        expected=[(i,0,j) for i in range(12) for j in range(3)]
        expected[33:33]=[(10,1,2),(10,1,0),(10,1,0),(10,1,0)]
        assert len(records)==40 and int(mt[6])==40 and int(mt[7])==675
        cases=model['cases']
        assert int(mt[8])==3*sum(c['m']*c['n']*c['groups'] for c in cases)+4*cases[10]['m']*cases[10]['n']*cases[10]['groups']
        for r,(cid,rec,mode) in zip(records,expected):
            assert (r['case_id'],r['recovery'],r['mode'])==(cid,rec,mode)
            c=cases[cid]
            assert (r['M'],r['N'],r['K'])==(c['m'],c['n'],c['k'])
            assert tuple(r[k] for k in ('ROWS','COLS','TILE_K','GROUP_SIZE','DOUBLE_BUFFER','BUS_BYTES','SCALE_ONCE','PACK_COLS','POST_OVERLAP','POST_PIPELINE','A_REUSE'))==(rows,cols,tk,group,db,bus,once,pack,overlap,pipeline,reuse)
            pred=traffic(c['m'],c['n'],c['k'],rows,cols,tk,group,bus,once,pack,reuse)
            for key,value in pred.items():
                if key!='tiles':assert r[key]==value,(name,cid,key,r[key],value)
            assert r['compute_cycles']+r['input_wait_cycles']+r['output_wait_cycles']+r['psum_wait_cycles']+r['post_drain_cycles']<=r['total_cycles']
            assert 0<=r['overlap_cycles']<=r['compute_cycles']
            assert r['padding_bytes']+r['weight_bytes']+r['activation_bytes']+r['scale_bytes']==r['input_beats']*bus
            count=((c['m']+rows-1)//rows)*((c['n']+cols-1)//cols)*c['groups']
            assert r['psum_groups']==count and r['post_issue_cycles']==count*rows*cols
            assert r['post_retire_cycles']==r['post_issue_cycles']
            output_tiles=((c['m']+rows-1)//rows)*((c['n']+cols-1)//cols)
            fixed=2*rows*cols*output_tiles+2*pred['tiles']+(rows*cols+2)*count+2*c['m']*c['n']+1
            assert r['total_cycles']==fixed+r['compute_cycles']+r['input_wait_cycles']+r['output_wait_cycles']+r['psum_wait_cycles']+r['post_drain_cycles'],('cycle classification',name,cid,r)
            assert 0<=r['compute_post_overlap_cycles']<=min(r['compute_cycles'],r['post_active_cycles'])
            if not overlap:assert r['compute_post_overlap_cycles']==0
            if not db:assert r['overlap_cycles']==0
        assert int(mt[11])>0
        if db:assert int(mt[10])>0
        assert int(mt[20])==int(mt[8]) and int(mt[22])>0 and int(mt[23])==1
        if overlap:assert int(mt[21])>0
        assert int(mt[24])==reuse
        if reuse:assert int(mt[25])>0 and int(mt[26])>0 and int(mt[27])>0
        if pack and cols>1 and bus==8:
            assert int(mt[15])>0 and int(mt[16])>0
        if tk%2:assert int(mt[17])>0
        summary['simulations'].append(dict(name=name,ROWS=rows,COLS=cols,TILE_K=tk,GROUP_SIZE=group,DOUBLE_BUFFER=db,BUS_BYTES=bus,SCALE_ONCE=once,PACK_COLS=pack,POST_OVERLAP=overlap,POST_PIPELINE=pipeline,A_REUSE=reuse,cache_hits=int(mt[25]),cache_writes=int(mt[26]),cache_switches=int(mt[27]),scaled_checks=int(mt[20]),full_queue_checks=int(mt[21]),held_pipe_checks=int(mt[22]),post_resets=int(mt[23]),dual_writes=int(mt[15]),holey_keeps=int(mt[16]),odd_k=int(mt[17]),tasks=40,outputs=675,psums=int(mt[8]),checks=int(mt[9]),cycles=records))
    old=ROOT/'build/sim_w4a8_post_overlap_pipe'
    identity(old)
    summary['post_baseline']=[{k:int(v) for k,v in r.items()} for r in csv.DictReader((old/'results.csv').open(encoding='utf-8-sig'))]
    ablation=next(x for x in summary['simulations'] if x['name']=='no_reuse')
    for r,previous in zip(ablation['cycles'],summary['post_baseline']):
        for field in previous:
            assert r[field]==previous[field],('exact no_reuse baseline',field,r,previous)
    default=next(x for x in summary['simulations'] if x['name']=='reuse')
    for r in default['cycles']:
        if r['recovery']:continue
        previous=next(p for p in summary['post_baseline'] if (p['case_id'],p['mode'],p['recovery'])==(r['case_id'],r['mode'],0))
        for field in ('weight_bytes','scale_bytes','valid_macs','compute_cycles'):
            assert r[field]==previous[field],('same arithmetic',field)
        assert r['activation_bytes']==r['M']*r['K']
    summary['totals']={key:sum(s[key] for s in summary['simulations']) for key in ('tasks','outputs','psums','checks')}
    summary['synthesis']={'completed':False};summary['ooc']={'completed':False}
    synth=ROOT/'build/synth_w4a8_reuse'
    if (synth/'primitive_counts.txt').exists():
        identity(synth);log=read(synth/'synth_w4a8_reuse.log')
        assert re.search(r'^W4A8_REUSE_SYNTHESIS_PASS',log,re.M) and not re.search(r'^ERROR:',log,re.M)
        pc=read(synth/'primitive_counts.txt')
        assert 'Latch_count=0' in pc and 'Blackbox_count=0' in pc
        assert not re.search(r'^CRITICAL WARNING:',log,re.M),'critical warning requires review'
        summary['synthesis']=dict(completed=True,part=re.search(r'^Part=(\S+)',pc,re.M)[1],
            utilization=utilization(synth/'utilization_synth.rpt'),timing=timing(synth/'timing_synth.rpt'),
            warnings=[line for line in log.splitlines() if line.startswith(('WARNING:','CRITICAL WARNING:'))])
        assert summary['synthesis']['part']=='xcvu9p-flga2104-2L-e'
        ram=read(synth/'ram_synth.rpt')
        cache=[dict(name=name,primitive=primitive,available_bits=int(avail),used_bits=int(used))
               for name,primitive,avail,used in re.findall(r'^\|\s+(activation_cache\.row_bank\[\d+\]\.ram/mem_reg)\s*\|\s*(RAMB36E2)\s*\|\s*BLOCK\s*\|\s*(\d+)\s*\|\s*(\d+)',ram,re.M)]
        assert len(cache)==4 and all(x['used_bits']==32768 and x['available_bits']==36864 for x in cache)
        summary['synthesis']['activation_cache_mapping']=cache
        u=summary['synthesis']['utilization']
        assert u['RAMB36']==5 and u['RAMB18']==2 and u['LUTRAM']==160 and u['DSP']==22 and u['URAM']==0
        dsp=read(synth/'dsp_mapping.txt').splitlines()[::2]
        assert len(dsp)==22 and sum('array_core' in name for name in dsp)==16
        summary['synthesis']['dsp_instances']=dsp
        for key in ('no_clock','unconstrained_internal_endpoints','latch_loops'):
            assert summary['synthesis']['timing']['checks'][key]==0
        if re.search(r'^W4A8_REUSE_OOC_FINISHED',log,re.M):
            route=read(synth/'route_status_ooc.rpt');drc=read(synth/'drc_ooc.rpt')
            rc={key:int(re.search(r'# of '+label+r'\.+\s*:\s*(\d+)',route)[1]) for key,label in [
                ('routable_nets','routable nets'),('fully_routed_nets','fully routed nets'),
                ('routing_errors','nets with routing errors'),('explicit_gaps','nets with explicit gaps')]}
            summary['ooc']=dict(completed=True,utilization=utilization(synth/'utilization_ooc.rpt'),
                timing=timing(synth/'timing_ooc.rpt'),route_status=rc,
                design_state=re.search(r'\| Design State\s*:\s*([^\r\n]+)',drc)[1].strip(),
                drc=[dict(rule=r,severity=se,description=ds.strip(),checks=int(ct)) for r,se,ds,ct in re.findall(r'^\|\s*([A-Z][A-Z0-9_-]+)\s*\|\s*(Warning|Error|Critical Warning)\s*\|\s*([^|]+)\s*\|\s*(\d+)\s*\|',drc,re.M)])
            assert rc['routing_errors']==0
            assert rc['fully_routed_nets']==rc['routable_nets']
            assert not any(x['severity'] in ('Error','Critical Warning') for x in summary['ooc']['drc'])
            summary['ooc']['internal_target_met']=(
                summary['ooc']['timing']['setup_failing_endpoints']==0 and
                summary['ooc']['timing']['hold_failing_endpoints']==0)
    neg=ROOT/'build/sim_w4a8_reuse_reuse_negative';summary['negative_probe']={'executed':False}
    if (neg/'observed_exit_code.txt').exists():
        identity(neg);code=int(read(neg/'observed_exit_code.txt'))
        assert code!=0 and 'W4A8_REUSE_CHECK_FAILED' in read(neg/'run.log') and not (neg/'PASS.txt').exists()
        summary['negative_probe']=dict(executed=True,exit_code=code)
    (ROOT/'build/w4a8_reuse_summary.json').write_text(json.dumps(summary,ensure_ascii=False,indent=2)+'\n',encoding='utf8')
    report(summary)
    files=['rtl/w4a8_reuse.sv','tb/w4a8_reuse_memory.sv','tb/tb_w4a8_reuse.sv',
           'model/w4a8_reference.py','scripts/reuse_traffic.py','scripts/run_w4a8_reuse.ps1',
           'scripts/synth_w4a8_reuse.tcl','scripts/summarize_w4a8_reuse.py','scripts/run_w4a8_reuse_vcs.sh',
           'docs/w4a8_numerics.md','docs/w4a8_reuse_architecture.md','docs/w4a8_reuse_validation.md',
           'docs/w4a8_reuse_performance.md','docs/w4a8_reuse_brief.md','docs/w4a8_next_steps.md',
           'README.md','config/project.json']
    delivery=dict(scope=summary['scope'],simulation_pass=True,totals=summary['totals'],
                  synthesis=summary['synthesis']['completed'],ooc=summary['ooc']['completed'],
                  internal_target_met=summary['ooc'].get('internal_target_met',False),
                  part=summary['synthesis'].get('part'),negative_probe=summary['negative_probe'],
                  vcs_compilation='not run; installation not found',files={})
    for name in files:
        data=(ROOT/name).read_bytes()
        delivery['files'][name]=dict(bytes=len(data),sha256=hashlib.sha256(data).hexdigest())
    delivery['pass']=delivery['synthesis'] and delivery['ooc'] and delivery['internal_target_met'] and delivery['negative_probe']['executed']
    (ROOT/'build/w4a8_reuse_delivery.json').write_text(json.dumps(delivery,ensure_ascii=False,indent=2)+'\n',encoding='utf8')
    print('W4A8_REUSE_ARTIFACT_AUDIT_PASS '+json.dumps(summary['totals']))
    print(json.dumps({'synthesis':{k:v for k,v in summary['synthesis'].items() if k!='warnings'},'ooc':summary['ooc']},indent=2))


def record(sim,cid,mode):return next(r for r in sim['cycles'] if (r['case_id'],r['mode'],r['recovery'])==(cid,mode,0))
def report(s):
    text='# 激活跨 N tile 复用：验证与性能报告\n\n'
    text+='本轮新增 w4a8_reuse；原 w4a8_post 及 INT8/NPU 实现保留。Windows PowerShell 5.1，Python 3.13.5，Vivado/XSim 2025.2 build6299465；临时评估 part xcvu9p-flga2104-2L-e，板卡/最终封装和速度等级未确认。\n\n'
    text+='## 实际验证\n\n'
    text+=table(['配置','阵列','K tile/group','总线字节','A复用','输入双bank','任务','输出','psum/scale比较','复用读','缓存写','epoch切换'],[[x['name'],f"{x['ROWS']}×{x['COLS']}",f"{x['TILE_K']}/{x['GROUP_SIZE']}",x['BUS_BYTES'],x['A_REUSE'],x['DOUBLE_BUFFER'],x['tasks'],x['outputs'],x['psums'],x['cache_hits'],x['cache_writes'],x['cache_switches']] for x in s['simulations']])
    text+=f"\n合计 {s['totals']['tasks']} 任务、{s['totals']['outputs']} 输出、{s['totals']['psums']} 整组 psum 与缩放乘积比较。cache_hits/cache_writes/cache_switches为整个TB过程累计，包含被复位中止的尝试，不能当作单个成功任务统计。输出逐元素完全一致；每 RUN 拍有效行 A 与全局矩阵地址对应；每缓存读检查当前 epoch 已写入，缓存写仅允许首个 N tile，读写同地址禁止。旧基线源码哈希一致；A_REUSE=0 的全部40条 CSV（含周期及恢复任务）与上一阶段默认配置逐字段一致。\n\n"
    text+='保留零/正负/INT4全部编码/边界/不同组scale/固定种子随机/矩形/尾块/跨tile/不完整group/GEMV/GEMM、连续任务、计算中/输出阻塞/scale流水中复位、输入持稳/输出背压、满psum队列恢复。新增2×3/tile5/group12与tile19验证非字对齐缓存地址，1×1验证输出累加依赖，单输入bank、1字节总线均实际仿真。每任务200000周期与全局20ms超时；失败fatal及无PASS由PowerShell转非零。故障探针：'+json.dumps(s['negative_probe'])+'。\n\n'
    text+='## 代表性任务：相同模式的对照\n\n'
    rows=[];default=next(x for x in s['simulations'] if x['name']=='reuse')
    for cid in (4,5):
        for mode in (0,1,2):
            r=record(default,cid,mode)
            p=next(p for p in s['post_baseline'] if (p['case_id'],p['mode'],p['recovery'])==(cid,mode,0))
            rows.append(['Decode 1×13×96' if cid==4 else 'Prefill 4×12×96',mode,p['activation_bytes'],r['activation_bytes'],p['input_beats'],r['input_beats'],p['total_cycles'],r['total_cycles'],f"{100*(1-r['total_cycles']/p['total_cycles']):.2f}%",r['input_wait_cycles'],r['compute_cycles'],r['compute_post_overlap_cycles'],f"{100*r['valid_macs']/(r['ROWS']*r['COLS']*r['total_cycles']):.2f}%"])
    text+=table(['任务','模式','旧A字节','新A字节','旧beat','新beat','旧周期','新周期','周期减少','等输入','RUN','RUN/post重叠','端到端MAC利用率'],rows)
    text+='\n模式0连续供数；模式1每请求首数据延迟5拍，8物理字节beat后等待7+4拍（每8字节burst gap4），padding计预算；模式2固定种子LFSR及周期输入/输出/post暂停。模式2策略相同，但任务周期改变后绝对ticks相位也改变，单次周期差不是严格逐拍相同的外部阻塞回放。模式0/1使用相同确定性供数规则。结果只代表此TB供数条件。\n\n'
    rows=[]
    for cid in (4,5):
        for name in ('reuse','no_reuse','words','single','one','byte'):
            x=next(x for x in s['simulations'] if x['name']==name)
            for mode in (0,1):
                r=record(x,cid,mode);rows.append([cid,name,mode,r['weight_bytes'],r['activation_bytes'],r['scale_bytes'],r['input_beats'],r['padding_bytes'],r['total_cycles'],r['input_wait_cycles'],r['post_drain_cycles']])
    text+='### 配置消融\n\n'+table(['case','配置','模式','W字节','A字节','scale字节','beat','padding','周期','等输入','post drain'],rows)
    text+='\n所有任务完整CSV见 build/sim_w4a8_reuse_*/results.csv。缓存不改变 W/scale 传输量、算法有效 MAC 和 RUN 周期；有效 A 字节恒为 M×K，不再乘 N tile 数。sx 暂仍跨 N 重传。计数器、group流水、数值合同与上一阶段一致，定义见 w4a8_post_architecture.md。闭式总周期审计每条记录通过：固定开销=2RC×输出tile数+2×请求tile数+(RC+2)×group数+2MN+1；总周期=固定开销+RUN+等输入+等输出+psum满等待+post drain。加载/post重叠是子集不能重复相加。默认16 MAC/拍，100MHz约束下1.6GMAC/s只是理论峰值。\n\n'
    text+='## 数值三层比较\n\nA：RTL对位精确模型逐输出/组psum/缩放乘积完全一致。B/C使用与上一阶段同一向量，缓存不改变量化算法。以下为合成 Prefill 随机浮点用例，不是模型准确率：\n\n'
    nums=[]
    for group in (32,12):
        case=json.loads(read(ROOT/f'build/w4a8_vectors/group{group}.json'))['cases'][5]
        nums.append({'group':group,'B_fixed_vs_float_quant':case['B_fixed_vs_float_quant'],'C_quant_vs_original':case['C_quant_vs_original']})
    text+='~~~json\n'+json.dumps(nums,ensure_ascii=False,indent=2)+'\n~~~\n\n'
    text+='## 实际 VU9P 综合及内部 OOC\n\n'
    if s['synthesis']['completed']:
        sy=s['synthesis'];u=sy['utilization'];rows=[['综合',*[u[k] for k in ('LUT','FF','DSP','RAMB18','RAMB36','LUTRAM','URAM')],sy['timing']['WNS_ns'],sy['timing']['WHS_ns']]]
        if s['ooc']['completed']:
            oc=s['ooc'];u=oc['utilization'];rows.append(['OOC',*[u[k] for k in ('LUT','FF','DSP','RAMB18','RAMB36','LUTRAM','URAM')],oc['timing']['WNS_ns'],oc['timing']['WHS_ns']])
        text+=table(['阶段','LUT','FF','DSP','RAMB18','RAMB36','LUTRAM','URAM','WNS ns','WHS ns'],rows)
        text+=f'\n默认激活缓存实际为四个512×64bit RAMB36E2，每bank使用32768/36864 bits（88.89%）；Y另占1 RAMB36E2、两组psum各1 RAMB18E2、W共160 LUTRAM。相对上一阶段2591LUT/3029FF，当前{int(sy["utilization"]["LUT"])}LUT/{int(sy["utilization"]["FF"])}FF，新增4个RAMB36，DSP仍22（16PE、5个scale、1个统计）。只默认4×4/tile8/group32/A复用/双W bank实际综合。latch/blackbox为0，DSP映射见 dsp_mapping.txt，缓存/psum/Y/W实际存储映射见 ram_synth.rpt（不得将RTL数组直接称为BRAM）。10ns时钟及虚拟OOC时钟源仅作内部评估，未设置板级管脚/I/O delay。\n\n'
        text+='~~~json\n'+json.dumps({'synthesis_timing':sy['timing'],'ooc':s['ooc']},ensure_ascii=False,indent=2)+'\n~~~\n\n'
        text+='综合日志及其OOC警告完整列表：\n\n~~~text\n'+'\n'.join(sy['warnings'])+'\n~~~\n\n'
    else:text+='本轮综合未运行或未完成，不引用历史资源作为本轮结果。\n\n'
    text+='## 范围与限制\n\n已实现且验证：表中配置和任务，缓存生命周期/初始化/同步读/读写冲突保护；默认综合/OOC见上。已实现但未验证：最大M/N/K尺寸和其他参数组合；MAX_K=4096仅综合容量，并非本轮矩阵规模测试上限；测试向量K最大96。VCS编译/运行未运行，本机未发现安装，新脚本仅Bash语法检查。未来：双M缓存跨epoch预取、sx缓存、输出tile重叠、Decode专用映射、NPU描述符适配、DDR/DMA与完整Transformer。仍是广播外积阵列，没有邻接PE传递的脉动阵列。\n\n'
    text+='单M epoch缓存禁止提前加载下一M tile，可能增加M切换等待；缓存按MAX_K分配，非整齐group/tile会产生padding，默认每行512×64bit，四行16KiB有效数据容量。最后word无效字节虽可存poison，但计算从不读取该范围。输入必须符合协商packet和keep合同；没有恶意输入包长度恢复协议。\n'
    (ROOT/'docs/w4a8_reuse_validation.md').write_text(text,encoding='utf8')

    perf='# 激活复用性能测量\n\n本报告由已通过源码/向量/CSV一致性检查的仿真产物生成。供数是TB模式，不是DDR或板上性能。默认4×4共16MAC/拍；1.6GMAC/s仅来自100MHz评估目标的理论值。\n\n'
    rows=[]
    for cid in (4,5):
        for mode in (0,1,2):
            r=record(default,cid,mode)
            p=next(p for p in s['post_baseline'] if (p['case_id'],p['mode'],p['recovery'])==(cid,mode,0))
            fixed=r['total_cycles']-sum(r[k] for k in ('compute_cycles','input_wait_cycles','output_wait_cycles','psum_wait_cycles','post_drain_cycles'))
            rows.append([cid,mode,r['total_cycles'],p['total_cycles'],r['weight_bytes'],r['activation_bytes'],r['scale_bytes'],r['input_beats']*r['BUS_BYTES'],r['padding_bytes'],r['valid_macs'],r['compute_cycles'],r['input_wait_cycles'],r['output_wait_cycles'],r['post_drain_cycles'],fixed,f"{100*r['input_wait_cycles']/r['total_cycles']:.2f}%",f"{100*r['valid_macs']/(16*r['total_cycles']):.2f}%"])
    perf+=table(['case','mode','周期','旧周期','W字节','A字节','scale字节','物理字节','padding','有效MAC','RUN','等输入','等输出','post drain','固定开销','等输入比例','端到端利用率'],rows)
    perf+='\ncase4=Decode 1×13×96，case5=Prefill4×12×96。RUN有效利用率分别1248/(16×384)=20.31%、4608/(16×288)=100%；端到端比率不能拿RUN比率代替。prefill连续供数775周期中固定开销427占55.10%，RUN288占37.16%，末组drain60占7.74%；带宽受限模式等输入997/1772=56.26%，因此控制/输出优化与供数优化的优先级取决于条件。\n\n'
    perf+='模式0每拍可接受一个beat；模式1每请求首延迟5、beat后cooldown=BUS_BYTES-1+burst gap（8物理字节边界额外4），首个packet请求会重新启动delay计数；不将该TB策略解释成严格跨packet全局DDR带宽预算。模式2LFSR固定种子0x20261012，另外周期输入暂停/输出背压/post暂停；绝对tick相位随周期变化。旧新硬件使用相同模型配置，但模式2不是逐拍相同阻塞回放。加载/计算重叠见原CSV overlap_cycles=RUN且接受输入beat；compute_post_overlap=RUN且post活动，均是子集，不参与互斥周期加总。\n\n'
    perf+='A_REUSE=0逐字段精确复现旧w4a8_post；A_REUSE=1对相同阵列减少A字节，W/scale/MAC/RUN保持相同。默认cache容量16KiB有效位，物理映射由综合报告确认。tile19、单W bank、1×1和1byte供数的消融见 [验证报告](w4a8_reuse_validation.md)，不同配置资源未全部综合，不宣称综合面积归一的加速比。\n\n'
    perf+='三个当前设计问题见 [后续计划](w4a8_next_steps.md)：输出tile流水/保存开销、Decode PE映射、NPU供数接口与M epoch预取。时序与路由是独立EDA证据，见验证报告；本轮没有板上tokens/s、实测频率或实际模型质量结果。\n'
    (ROOT/'docs/w4a8_reuse_performance.md').write_text(perf,encoding='utf8')
    brief='# 激活跨 N tile 复用：内部交流摘要\n\n'
    brief+=f"当前 w4a8_reuse 实现 per-row 同步全K激活缓存、packed INT4双权重Buffer、广播MAC、双组psum、独立定点scale流水与背压输出。新增缓存复用协议 req_activation；已验证 {s['totals']['tasks']} 任务/{s['totals']['outputs']} 输出/{s['totals']['psums']} 组psum与scaled乘积。\n\n"
    r=record(default,5,1);p=next(p for p in s['post_baseline'] if (p['case_id'],p['mode'],p['recovery'])==(5,1,0))
    brief+=f"代表性4×12×96 Prefill：第一个N tile加载384字节A并写四个行缓存，计算36个tile请求中的首12个；后两个N tile从相同缓存读取A，仅加载W和scale。总A由{p['activation_bytes']}降到{r['activation_bytes']}字节，beat {p['input_beats']}→{r['input_beats']}；带宽受限周期 {p['total_cycles']}→{r['total_cycles']}，等输入 {p['input_wait_cycles']}→{r['input_wait_cycles']}。位精确数值不变，RUN仍288拍。\n\n"
    if s['synthesis']['completed']:
        u=s['synthesis']['utilization'];brief+=f"实际默认综合：{int(u['LUT'])} LUT/{int(u['FF'])} FF/{int(u['DSP'])} DSP/{int(u['RAMB18'])} RAMB18/{int(u['RAMB36'])} RAMB36；临时VU9P part。\n\n"
    if s['ooc']['completed']:
        t=s['ooc']['timing'];brief+=f"10ns内部OOC：WNS {t['WNS_ns']:+.3f}ns、WHS {t['WHS_ns']:+.3f}ns；路由/DRC边界见验证报告，不宣称板上频率。\n\n"
    brief+='瓶颈随供数条件不同：连续供数本来不等输入，A复用主要降低字节量；限带宽仍有权重/scale加载和串行tile边界开销。下一步优先比较输出tile流水/更长K tile，再讨论Decode行利用率与NPU任务描述符；M epoch预取需增加第二套缓存并测收益，不能仅扩大阵列。无真实DDR/完整模型，VCS未运行。\n'
    (ROOT/'docs/w4a8_reuse_brief.md').write_text(brief,encoding='utf8')
if __name__=='__main__':main()
