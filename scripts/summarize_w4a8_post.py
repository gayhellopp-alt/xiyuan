"""Audit incremental wide-input W4A8 implementation and measured ablation results."""
import csv,hashlib,json,re,sys
from pathlib import Path
sys.dont_write_bytecode=True
from summarize import read,utilization,timing
from packed_traffic import traffic
ROOT=Path(__file__).resolve().parents[1]
CONFIGS=[('overlap_pipe',4,4,8,32,1,1,1),('serial',4,4,8,32,1,0,0),
         ('pipe_serial',4,4,8,32,1,0,1),('scalar_overlap',4,4,8,32,1,1,0),
         ('alt',2,3,5,12,1,1,1),('single',4,4,8,32,0,1,1),('one',1,1,8,32,1,1,1)]

def identity(work):
    saved=json.loads(read(work/'source_inputs.json'))
    for name,digest in saved['files'].items():
        assert hashlib.sha256((ROOT/name).read_bytes()).hexdigest()==digest,name
    return saved
def table(headers,rows):
    return '| '+' | '.join(headers)+' |\n|'+ '|'.join(['---']*len(headers))+'|\n'+''.join('| '+' | '.join(map(str,r))+' |\n' for r in rows)
def main():
    summary={'scope':'Double psum buffer and independent globally-stalled post pipeline; no DDR','simulations':[]}
    for name,rows,cols,tk,group,db,overlap,pipeline in CONFIGS:
        bus=8;once=1;pack=1
        work=ROOT/f'build/sim_w4a8_post_{name}'
        identity(work)
        assert (work/'vectors.txt').read_bytes()==(ROOT/f'build/w4a8_vectors/group{group}.txt').read_bytes()
        model=json.loads(read(ROOT/f'build/w4a8_vectors/group{group}.json'))
        log=read(work/'run.log')
        assert read(work/'PASS.txt').strip()=='PASS' and not re.search(r'Fatal:|FAILED|TIMEOUT|^ERROR:',log,re.M)
        mt=re.search(r'W4A8_POST_TESTS_PASS rows=(\d+) cols=(\d+) tile=(\d+) group=(\d+) db=(\d+) tasks=(\d+) outputs=(\d+) psums=(\d+) checks=(\d+) overlap=(\d+) held_inputs=(\d+) bytes=(\d+) scale_once=(\d+) pack=(\d+) dual_writes=(\d+) holey_keeps=(\d+) odd_k=(\d+) post_overlap=(\d+) pipeline=(\d+) scaled=(\d+) full_queue=(\d+) held_pipe=(\d+) post_resets=(\d+)',log)
        assert mt and tuple(map(int,mt.group(1,2,3,4,5,12,13,14,18,19)))==(rows,cols,tk,group,db,bus,once,pack,overlap,pipeline)
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
            assert tuple(r[k] for k in ('ROWS','COLS','TILE_K','GROUP_SIZE','DOUBLE_BUFFER','BUS_BYTES','SCALE_ONCE','PACK_COLS','POST_OVERLAP','POST_PIPELINE'))==(rows,cols,tk,group,db,bus,once,pack,overlap,pipeline)
            pred=traffic(c['m'],c['n'],c['k'],rows,cols,tk,group,bus,once,pack)
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
        if pack and cols>1:
            assert int(mt[15])>0 and int(mt[16])>0
        if tk%2:assert int(mt[17])>0
        summary['simulations'].append(dict(name=name,ROWS=rows,COLS=cols,TILE_K=tk,GROUP_SIZE=group,DOUBLE_BUFFER=db,BUS_BYTES=bus,SCALE_ONCE=once,PACK_COLS=pack,POST_OVERLAP=overlap,POST_PIPELINE=pipeline,scaled_checks=int(mt[20]),full_queue_checks=int(mt[21]),held_pipe_checks=int(mt[22]),post_resets=int(mt[23]),dual_writes=int(mt[15]),holey_keeps=int(mt[16]),odd_k=int(mt[17]),tasks=40,outputs=675,psums=int(mt[8]),checks=int(mt[9]),cycles=records))
    old=ROOT/'build/sim_w4a8_packed_paired'
    identity(old)
    summary['packed_baseline']=[{k:int(v) for k,v in r.items()} for r in csv.DictReader((old/'results.csv').open(encoding='utf-8-sig'))]
    for current in summary['simulations']:
        if current['name'] not in ('overlap_pipe','serial','pipe_serial','scalar_overlap'):continue
        for r in current['cycles']:
            if r['recovery']:continue
            previous=next(p for p in summary['packed_baseline'] if (p['case_id'],p['mode'],p['recovery'])==(r['case_id'],r['mode'],0))
            for field in ('weight_bytes','activation_bytes','scale_bytes','valid_macs','compute_cycles','input_beats','padding_bytes'):
                assert r[field]==previous[field],(current['name'],field)
    summary['totals']={key:sum(s[key] for s in summary['simulations']) for key in ('tasks','outputs','psums','checks')}
    summary['synthesis']={'completed':False};summary['ooc']={'completed':False}
    synth=ROOT/'build/synth_w4a8_post'
    if (synth/'primitive_counts.txt').exists():
        identity(synth);log=read(synth/'synth_w4a8_post.log')
        assert re.search(r'^W4A8_POST_SYNTHESIS_PASS',log,re.M) and not re.search(r'^ERROR:',log,re.M)
        pc=read(synth/'primitive_counts.txt')
        assert 'Latch_count=0' in pc and 'Blackbox_count=0' in pc
        summary['synthesis']=dict(completed=True,part=re.search(r'^Part=(\S+)',pc,re.M)[1],
            utilization=utilization(synth/'utilization_synth.rpt'),timing=timing(synth/'timing_synth.rpt'),
            warnings=[line for line in log.splitlines() if line.startswith(('WARNING:','CRITICAL WARNING:'))])
        assert summary['synthesis']['part']=='xcvu9p-flga2104-2L-e'
        for key in ('no_clock','unconstrained_internal_endpoints','latch_loops'):
            assert summary['synthesis']['timing']['checks'][key]==0
        if re.search(r'^W4A8_POST_OOC_FINISHED',log,re.M):
            route=read(synth/'route_status_ooc.rpt');drc=read(synth/'drc_ooc.rpt')
            rc={key:int(re.search(r'# of '+label+r'\.+\s*:\s*(\d+)',route)[1]) for key,label in [
                ('routable_nets','routable nets'),('fully_routed_nets','fully routed nets'),
                ('routing_errors','nets with routing errors'),('explicit_gaps','nets with explicit gaps')]}
            summary['ooc']=dict(completed=True,utilization=utilization(synth/'utilization_ooc.rpt'),
                timing=timing(synth/'timing_ooc.rpt'),route_status=rc,
                design_state=re.search(r'\| Design State\s*:\s*([^\r\n]+)',drc)[1].strip(),
                drc=[dict(rule=r,severity=se,description=ds.strip(),checks=int(ct)) for r,se,ds,ct in re.findall(r'^\|\s*([A-Z][A-Z0-9_-]+)\s*\|\s*(Warning|Error|Critical Warning)\s*\|\s*([^|]+)\s*\|\s*(\d+)\s*\|',drc,re.M)])
            assert rc['routing_errors']==0
    neg=ROOT/'build/sim_w4a8_post_overlap_pipe_negative';summary['negative_probe']={'executed':False}
    if (neg/'observed_exit_code.txt').exists():
        identity(neg);code=int(read(neg/'observed_exit_code.txt'))
        assert code!=0 and 'W4A8_POST_CHECK_FAILED' in read(neg/'run.log') and not (neg/'PASS.txt').exists()
        summary['negative_probe']=dict(executed=True,exit_code=code)
    (ROOT/'build/w4a8_post_summary.json').write_text(json.dumps(summary,ensure_ascii=False,indent=2)+'\n',encoding='utf8')
    report(summary)
    print('W4A8_POST_ARTIFACT_AUDIT_PASS '+json.dumps(summary['totals']))
    print(json.dumps({'synthesis':{k:v for k,v in summary['synthesis'].items() if k!='warnings'},'ooc':summary['ooc']},indent=2))

def record(sim,cid,mode):return next(r for r in sim['cycles'] if (r['case_id'],r['mode'],r['recovery'])==(cid,mode,0))
def report(s):
    text='# W4A8 双 psum Buffer 与独立 scale 流水：实际报告\n\n'
    text+='新增w4a8_post；保留原w4a8_packed及其源哈希/报告。输入列对packet和数值合同未变，变化为两组group snapshot与独立后处理。工具为Windows PowerShell5.1/Python3.13.5/Vivado-XSim2025.2 Build6299465；part为xcvu9p-flga2104-2L-e临时评估选择，板卡未确认。\n\n'
    text+='## 已运行验证\n\n'
    text+=table(['配置','overlap','pipeline','阵列/group','任务','输出','psum/缩放乘积','满队列检查','流水持稳检查'],[[x['name'],x['POST_OVERLAP'],x['POST_PIPELINE'],f"{x['ROWS']}×{x['COLS']}/{x['GROUP_SIZE']}",x['tasks'],x['outputs'],x['psums'],x['full_queue_checks'],x['held_pipe_checks']] for x in s['simulations']])
    text+='\n每配置36正常任务+4附加任务：计算中复位恢复、输出受阻复位恢复、后处理冻结至Buffer满后恢复、流水有数据时复位恢复。全输出和group INT32 psum逐项一致，并逐有效槽比较psum×sx×sw的64bit乘积。覆盖不同scale/group、尾块、GEMV/GEMM、INT4边界/全部编码、正负/随机/零、连续任务、输入暂停、输出背压、metadata、bank所有权、输出RAM读写仲裁、暂停时流水valid/tag/data持稳。1×1阵列专门覆盖单地址组间读写依赖。\n\n'
    text+='超时每任务200000周期，全局20ms；fatal/PASS由PowerShell额外检查，失败非零。故障注入：'+json.dumps(s['negative_probe'])+'。A位精确通过；量化B/C误差沿用同一向量与数值合同，见w4a8_validation.md，不代表真实模型准确率。\n\n'
    text+='## 代表性周期与消融\n\n'
    rows=[];default=next(x for x in s['simulations'] if x['name']=='overlap_pipe')
    for cid in (4,5):
        for mode in (0,1,2):
            old=next(r for r in s['packed_baseline'] if (r['case_id'],r['mode'],r['recovery'])==(cid,mode,0))
            for name in ('serial','pipe_serial','scalar_overlap','overlap_pipe'):
                sim=next(x for x in s['simulations'] if x['name']==name);r=record(sim,cid,mode)
                rows.append(['Decode 1×13×96' if cid==4 else 'Prefill 4×12×96',mode,name,r['total_cycles'],old['total_cycles'],f"{100*(1-r['total_cycles']/old['total_cycles']):.2f}%",r['compute_cycles'],r['post_active_cycles'],r['compute_post_overlap_cycles'],r['post_drain_cycles'],r['psum_wait_cycles'],r['input_wait_cycles'],r['output_wait_cycles'],f"{100*r['valid_macs']/(r['ROWS']*r['COLS']*r['total_cycles']):.2f}%"])
    text+=table(['任务','模式','配置','周期','旧列对周期','相对旧版减少','RUN','后处理活动','计算/后处理重叠','drain','psum满等待','等输入','等输出','MAC利用率'],rows)
    text+='\nserial为新controller关闭流水/重叠，包含snapshot交付和独立控制的额外周期，不声称与旧单状态机周期完全一致。mode0连续beat；mode1保持上一轮物理字节预算及首延迟/burst；mode2仍有LFSR/输入/输出暂停，另加入周期post_pause。mode2与旧版暂停条件不同，不能将全部周期差归因于流水。\n\n'
    text+='## 计数定义与端口约束\n\n'
    text+='psum_groups：保存完整snapshot的组数；post_issue/retire：物理RC槽读请求/写回拍，包括尾槽0；预期均为output_tile_count×group_count×RC。compute_post_overlap：RUN且post状态活动，是RUN子集，post活动包括post_pause。post_active：P_STREAM状态周期；post_drain：核心WAIT_POST周期；psum_wait：WAIT_PSUM且目标bank非FREE。compute/input_wait/output_wait/psum_wait/post_drain互斥，不能将重叠指标或post_active重复加总。统计32位，每合法start清零，done后保持。另独立审计总周期闭式分类：固定开销=2RC×输出tile数+2×输入tile数+(RC+2)×group数+2MN+1，总周期=固定开销+RUN+input_wait+output_wait+psum_wait+post_drain。固定项涵盖初始化、同步读/交付、逐槽保存和输出，而不重复加post_active。\n\n'
    text+='两个32bit psum RAM各单同步读/单写，64bit输出RAM单读/单写；后处理issue同步读psum/Y并寄存factor，下一enabled拍寄存scaled/Ybase，再下一拍写Y。流水每enabled拍一个slot，暂停整体冻结并禁止读写。仅一个group进入后处理，上一group最后写回后才取下一group，避免同地址组间RAW hazard；所有组完成才输出。CORE INIT_Y/OUT_REQ与后处理RAM访问互斥。每组仍用RC拍保存PE，未做PE双阵列。\n\n'
    text+='有效MAC不计填零，默认16MAC/拍，100MHz目标的1.6GMAC/s是理论上限；供数/暂停来自TB，不代表DDR、板上频率或token/s。输入字节/beat/padding与旧版匹配，优化没有减少算法MAC或改变量化精度。\n\n'
    text+='## VU9P 综合与内部时序\n\n'
    if s['synthesis']['completed']:
        sy=s['synthesis'];u=sy['utilization'];rows=[['综合',*[u.get(k,'—') for k in ('LUT','FF','DSP','RAMB18','RAMB36','LUTRAM','URAM')],sy['timing']['WNS_ns'],sy['timing']['WHS_ns']]]
        if s['ooc']['completed']:
            oc=s['ooc'];u=oc['utilization'];rows.append(['OOC',*[u.get(k,'—') for k in ('LUT','FF','DSP','RAMB18','RAMB36','LUTRAM','URAM')],oc['timing']['WNS_ns'],oc['timing']['WHS_ns']])
        text+=table(['阶段','LUT','FF','DSP','RAMB18','RAMB36','LUTRAM','URAM','WNS ns','WHS ns'],rows)
        text+='\n默认4×4/group32/双输入bank/两psum bank/流水重叠已实际综合，latch=0、blackbox=0。其他配置只仿真。实际两组psum各映射RAMB18，输出累加RAMB36，W bank共160 LUTRAM，A bank为FF；相较旧列对综合，新增267 LUT、694 FF与1个RAMB18，DSP数量不变。浅psum RAM被工具建议改LUTRAM，本轮保留BRAM同步行为与对照，未做该额外优化。存储映射见ram_synth.rpt，DSP实际实例见dsp_mapping.txt。10ns约束和虚拟BUFGCE_X0Y0仅用于内部评估，无板级管脚/I/O延迟。\n\n'
        text+='~~~json\n'+json.dumps({'synthesis_timing':sy['timing'],'ooc':s['ooc']},ensure_ascii=False,indent=2)+'\n~~~\n\n'
        text+='实际工具警告（完整保留）：\n\n~~~text\n'+'\n'.join(sy['warnings'])+'\n~~~\n\n'
    else:text+='本轮综合未运行/完成，不引用旧资源冒充本轮结果。\n\n'
    text+='## 限制与后续\n\n已实现且验证：表中七组合、位精确/乘积/ownership/压力/复位，默认综合/OOC状态如上。未验证：其他参数、最大逻辑尺寸、VCS编译执行。新VCS入口为run_w4a8_post_vcs.sh，仅Bash -n实际通过；编译执行未运行，未安装工具或申请许可证。两psum bank固定深度2；组间不同时在scale流水中，输出tile间未重叠；metadata与scale为FF，小RAM位利用率低。A跨N复用、专门Decode映射、脉动对照、NPU队列适配、真实DDR/DMA及完整Transformer仍未实现。\n\n'
    text+='原始CSV/命令/source_inputs位于build/sim_w4a8_post_*，EDA在build/synth_w4a8_post，汇总build/w4a8_post_summary.json，接口/lifecycle见w4a8_post_architecture.md。\n'
    (ROOT/'docs/w4a8_post_validation.md').write_text(text,encoding='utf8')
    brief='# 独立 group 后处理：内部交流摘要\n\n'
    brief+=f"新增w4a8_post：两组INT32 psum snapshot、独立scale流水、可控post_pause，捕获scale和坐标后释放operand bank。已运行{s['totals']['tasks']}任务/{s['totals']['outputs']}输出/{s['totals']['psums']}group psum及缩放乘积逐项比较；七配置含串行/流水/重叠消融、备用阵列、单输入bank和1×1地址依赖。\n\n"
    rows=[]
    for cid in (4,5):
        for mode in (0,1,2):
            old=next(r for r in s['packed_baseline'] if (r['case_id'],r['mode'],r['recovery'])==(cid,mode,0));r=record(default,cid,mode)
            rows.append(['Decode' if cid==4 else 'Prefill',mode,old['total_cycles'],r['total_cycles'],r['compute_post_overlap_cycles'],r['post_drain_cycles']])
    brief+=table(['任务','模式','旧列对周期','新周期','RUN/post重叠','drain'],rows)
    r=record(default,5,0)
    brief+=f"\n代表性Prefill：36输入请求与234beat保持不变，9group各保存16psum，再交给另一controller缩放合并。每group16个slot流水18enabled拍，累计144次issue/retire。末group写回后才输出当前N tile。总{r['total_cycles']}周期、RUN{r['compute_cycles']}、等输入{r['input_wait_cycles']}、末组drain{r['post_drain_cycles']}。冻结后处理使两bank占满，计算保持未保存psum等待；恢复与流水中途复位已验证。\n\n"
    if s['synthesis']['completed']:
        u=s['synthesis']['utilization']
        brief+=f"默认VU9P临时part综合：{int(u['LUT'])} LUT/{int(u['FF'])} FF/{int(u['DSP'])} DSP/{int(u['RAMB18'])} RAMB18/{int(u['RAMB36'])} RAMB36/{int(u['LUTRAM'])} LUTRAM，0URAM/0latch。\n\n"
        if s['ooc']['completed']:
            oc=s['ooc'];brief+=f"OOC10ns内部WNS{oc['timing']['WNS_ns']:+.3f}ns/WHS{oc['timing']['WHS_ns']:+.3f}ns；{oc['route_status']}，DRC/I/O边界见报告，不能宣称板上频率。\n\n"
        else:brief+='OOC未运行或未完成。\n\n'
    else:brief+='综合未运行或未完成。\n\n'
    brief+='下一步应依据剩余周期/带宽对照讨论A复用与更长K tile、输出tile层重叠、Decode N/K映射及NPU描述符适配；脉动阵列需同接口对照测量。当前仍广播阵列，无DDR/DMA/完整模型。模式2新增post暂停，旧版对照条件不同；不宣称DDR或板上性能。\n'
    (ROOT/'docs/w4a8_post_brief.md').write_text(brief,encoding='utf8')
if __name__=='__main__':main()
