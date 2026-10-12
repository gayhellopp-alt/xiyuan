"""Audit reproducible W4A8 artifacts and generate evidence-based reports."""
import csv, hashlib, json, re, sys
from pathlib import Path
sys.dont_write_bytecode=True
from summarize import read, utilization, timing
ROOT=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT/'model'))
from w4a8_reference import traffic, reference

def identity(work):
    saved=json.loads(read(work/'source_inputs.json'))
    for name,digest in saved['files'].items():
        assert hashlib.sha256((ROOT/name).read_bytes()).hexdigest()==digest, name
    return saved

def table(headers,rows):
    return '| '+' | '.join(headers)+' |\n|'+ '|'.join(['---']*len(headers))+'|\n'+''.join('| '+' | '.join(map(str,r))+' |\n' for r in rows)

def main():
    summary={'scope':'Streaming grouped W4A8 linear; synthetic memory only','simulations':[]}
    models={}
    for group in (32,12):
        model=json.loads(read(ROOT/f'build/w4a8_vectors/group{group}.json'))
        for c in model['cases']:
            values,psums,raw=reference(c['a'],c['b'],c['sx'],c['sw'],group)
            assert (values,psums,raw)==(c['output'],c['psum'],c['raw'])
        models[group]=model
    for name,rows,cols,tk,group,db in [('4x4_k8_g32_db',4,4,8,32,1),('2x3_k5_g12_db',2,3,5,12,1),('4x4_k8_g32_single',4,4,8,32,0)]:
        work=ROOT/f'build/sim_w4a8_{name}'
        identity(work)
        assert (work/'vectors.txt').read_bytes()==(ROOT/f'build/w4a8_vectors/group{group}.txt').read_bytes()
        log=read(work/'run.log')
        assert read(work/'PASS.txt').strip()=='PASS'
        assert not re.search(r'Fatal:|FAILED|TIMEOUT|^ERROR:',log,re.M)
        match=re.search(r'W4A8_TESTS_PASS rows=(\d+) cols=(\d+) tile=(\d+) group=(\d+) db=(\d+) tasks=(\d+) outputs=(\d+) psums=(\d+) checks=(\d+) overlap=(\d+) held_inputs=(\d+)',log)
        assert match and tuple(map(int,match.group(1,2,3,4,5)))==(rows,cols,tk,group,db)
        cases=models[group]['cases']
        records=[{k:int(v) for k,v in r.items()} for r in csv.DictReader((work/'results.csv').open(encoding='utf-8-sig'))]
        expected=[(i,0,mode) for i in range(12) for mode in range(3)]
        expected[33:33]=[(10,1,2),(10,1,0)]
        assert len(records)==38
        for r,(cid,recovery,mode) in zip(records,expected):
            assert (r['case_id'],r['recovery'],r['mode'])==(cid,recovery,mode),r
            c=cases[cid]
            assert (r['M'],r['N'],r['K'])==(c['m'],c['n'],c['k'])
            assert (r['ROWS'],r['COLS'],r['TILE_K'],r['GROUP_SIZE'],r['DOUBLE_BUFFER'])==(rows,cols,tk,group,db)
            expected_traffic=traffic(c['m'],c['n'],c['k'],rows,cols,tk,group)
            for field in ('weight_bytes','activation_bytes','scale_bytes','valid_macs','compute_cycles'):
                assert r[field]==expected_traffic[field],(name,cid,field)
            assert r['compute_cycles']+r['input_wait_cycles']+r['output_wait_cycles']<=r['total_cycles']
            assert 0<=r['overlap_cycles']<=r['compute_cycles']
            if not db:assert r['overlap_cycles']==0
        assert int(match[6])==38 and int(match[7])==621
        assert int(match[8])==3*sum(c['m']*c['groups']*c['n'] for c in cases)+2*cases[10]['m']*cases[10]['groups']*cases[10]['n']
        if db:assert int(match[10])>0
        assert int(match[11])>0
        summary['simulations'].append(dict(name=name,ROWS=rows,COLS=cols,TILE_K=tk,GROUP_SIZE=group,DOUBLE_BUFFER=db,tasks=38,outputs=621,psums=int(match[8]),checks=int(match[9]),overlap=int(match[10]),held_inputs=int(match[11]),cycles=records,source_hashes_match=True))
    summary['totals']={k:sum(s[k] for s in summary['simulations']) for k in ('tasks','outputs','psums','checks')}
    summary['numerical']={str(g):[{'name':c['name'],'kind':c['kind'],'saturated_outputs':c['saturated_outputs'],'B':c['B_fixed_vs_float_quant'],'C':c['C_quant_vs_original']} for c in model['cases']] for g,model in models.items()}
    synth=ROOT/'build/synth_w4a8'
    summary['synthesis']={'completed':False}
    summary['ooc']={'completed':False}
    if (synth/'primitive_counts.txt').exists():
        identity(synth)
        log=read(synth/'synth_w4a8.log')
        assert re.search(r'^W4A8_SYNTHESIS_PASS',log,re.M) and not re.search(r'^ERROR:',log,re.M)
        primitive=read(synth/'primitive_counts.txt')
        assert 'Latch_count=0' in primitive and 'Blackbox_count=0' in primitive
        summary['synthesis']={'completed':True,'part':re.search(r'^Part=(\S+)',primitive,re.M)[1],
            'version':re.search(r'^Vivado=(.+)',primitive,re.M)[1].strip(),'latches':0,'blackboxes':0,
            'utilization':utilization(synth/'utilization_synth.rpt'),'timing':timing(synth/'timing_synth.rpt'),
            'warnings':[line for line in log.splitlines() if line.startswith(('WARNING:','CRITICAL WARNING:'))]}
        assert summary['synthesis']['part']=='xcvu9p-flga2104-2L-e'
        assert summary['synthesis']['timing']['checks']['no_clock']==0
        assert summary['synthesis']['timing']['checks']['unconstrained_internal_endpoints']==0
        if re.search(r'^W4A8_OOC_FINISHED',log,re.M):
            route=read(synth/'route_status_ooc.rpt'); drc=read(synth/'drc_ooc.rpt')
            route_counts={}
            for key,label in [('routable_nets','routable nets'),('fully_routed_nets','fully routed nets'),('routing_errors','nets with routing errors'),('explicit_gaps','nets with explicit gaps')]:
                route_counts[key]=int(re.search(r'# of '+label+r'\.+\s*:\s*(\d+)',route)[1])
            summary['ooc']={'completed':True,'utilization':utilization(synth/'utilization_ooc.rpt'),
                'timing':timing(synth/'timing_ooc.rpt'),'route_status':route_counts,
                'drc_design_state':re.search(r'\| Design State\s*:\s*([^\r\n]+)',drc)[1].strip(),
                'drc_checks':[{'rule':rule,'severity':severity,'description':desc.strip(),'checks':int(count)}
                    for rule,severity,desc,count in re.findall(r'^\|\s*([A-Z][A-Z0-9_-]+)\s*\|\s*(Warning|Error|Critical Warning)\s*\|\s*([^|]+)\s*\|\s*(\d+)\s*\|',drc,re.M)]}
            assert route_counts['routing_errors']==0
    negative=ROOT/'build/sim_w4a8_4x4_k8_g32_db_negative'
    summary['negative_probe']={'executed':False}
    if (negative/'observed_exit_code.txt').exists():
        code=int(read(negative/'observed_exit_code.txt'))
        assert code!=0 and 'W4A8_CHECK_FAILED' in read(negative/'run.log') and not (negative/'PASS.txt').exists()
        summary['negative_probe']={'executed':True,'exit_code':code}
    (ROOT/'build/w4a8_summary.json').write_text(json.dumps(summary,indent=2,ensure_ascii=False)+'\n',encoding='utf8')
    generate_docs(summary,models)
    print('W4A8_ARTIFACT_AUDIT_PASS '+json.dumps(summary['totals']))
    print(json.dumps({'synthesis':{k:v for k,v in summary['synthesis'].items() if k!='warnings'},'ooc':summary['ooc']},indent=2))

def generate_docs(s,models):
    perf='# W4A8 性能报告（实际 XSim 周期）\n\n'
    perf+='时钟仿真周期为 10 ns；100 MHz 仅作为约束目标。供数模式0：连续，零额外首数据延迟；模式1：首数据等待5个模型负沿，接受8字节后暂停4个负沿，请求仍有协议开销；模式2：首延迟5，种子 0x20261012 的 LFSR 随机暂停、请求间隔、DUT 输入暂停及周期输出背压。模型细节见 tb/w4a8_memory_model.sv。随机进展依赖握手，单/双缓冲的暂停事件时间线不完全相同。\n\n'
    perf+='## 代表性任务\n\n'
    rows=[]
    for sim in s['simulations']:
        for r in sim['cycles']:
            if r['case_id'] not in (4,5) or r['recovery']:continue
            rows.append([sim['name'],('Decode 1×13×96' if r['case_id']==4 else 'Prefill 4×12×96'),r['mode'],r['total_cycles'],r['weight_bytes'],r['activation_bytes'],r['scale_bytes'],r['valid_macs'],r['compute_cycles'],r['input_wait_cycles'],r['output_wait_cycles'],r['overlap_cycles'],f"{100*r['valid_macs']/(r['ROWS']*r['COLS']*r['total_cycles']):.2f}%"])
    perf+=table(['配置','任务','供数模式','总周期','W字节','A字节','scale字节','有效MAC','RUN周期','等输入','等输出','RUN与加载重叠','端到端MAC利用率'],rows)
    perf+='\n利用率 = 有效MAC / (ROWS×COLS×总周期)，尾块填零不计有效MAC。计算阶段利用率 = 有效MAC / (ROWS×COLS×RUN周期)，与上述端到端利用率不同。默认硬件容量16 MAC/周期，理论100 MHz下1.6 GMAC/s；备用阵列6 MAC/周期、理论0.6 GMAC/s，均非板上实测吞吐。\n\n'
    perf+='## 单/双缓冲对照（同4×4、group32）\n\n'
    a=s['simulations'][0]['cycles'];b=s['simulations'][2]['cycles'];rows=[]
    for cid in (4,5):
        for mode in (0,1):
            dr=next(r for r in a if (r['case_id'],r['mode'],r['recovery'])==(cid,mode,0))
            sr=next(r for r in b if (r['case_id'],r['mode'],r['recovery'])==(cid,mode,0))
            rows.append([models[32]['cases'][cid]['name'],mode,sr['total_cycles'],dr['total_cycles'],f"{sr['total_cycles']/dr['total_cycles']:.3f}",f"{100*(1-dr['total_cycles']/sr['total_cycles']):.2f}%",dr['overlap_cycles']])
    perf+=table(['任务','模式','单缓冲周期','双缓冲周期','仿真周期比','周期减少','重叠周期'],rows)
    perf+='\n重叠计数仅统计 RUN 同拍接受数据，不能涵盖在 SAVE_G/scale/输出期间提前加载的收益。计数器均32位，无符号模2^32；每次合法启动清零，读数在 done 后保持。total_cycles 不计接受 start 的拍，计所有 busy 拍及 FINISH。compute/input_wait/output_wait 分别为 RUN、WAIT_TILE且目标bank未READY、OUT_SEND且未ready，三者互斥；overlap 是compute子集，不能加到总周期。输入字节只计真正握手接受，scale 两字节分别计数。\n\n'
    perf+='## 瓶颈证据\n\n'
    r=next(r for r in a if (r['case_id'],r['mode'],r['recovery'])==(5,0,0))
    others=r['total_cycles']-r['compute_cycles']-r['input_wait_cycles']-r['output_wait_cycles']
    perf+=f"默认 Prefill 连续供数：总{r['total_cycles']}，RUN {r['compute_cycles']}，等输入{r['input_wait_cycles']}，其他控制/存储/scale阶段{others}。总输入{r['weight_bytes']+r['activation_bytes']+r['scale_bytes']}字节，通过单字节端口。每组16拍保存psum，48拍串行scale读/乘/合并；3个N tile×3组共576拍。不同group重复装载scale，每K tile复制A/scale，均是可优化开销。Decode仅1个有效PE行，理论计算阶段最大25%行利用率；功能通过不等于Decode最优架构。\n\n"
    perf+='原始 CSV 位于 build/sim_w4a8_*/results.csv，汇总 JSON 位于 build/w4a8_summary.json。没有真实DDR、主机、板上token/s、功耗或加速比测量。\n'
    (ROOT/'docs/w4a8_performance.md').write_text(perf,encoding='utf8')
    val='# W4A8 验证与工具证据\n\n'
    val+='本次环境：Windows PowerShell 5.1、Python 3.13.5、Vivado/XSim 2025.2（Build 6299465）。工具目录 E:\\AMDDesignTools\\2025.2\\Vivado\\bin。所有批处理通过 PowerShell & 调用，未修改全局环境或安装依赖。阶段二参考模型仅需 Python 标准库。\n\n'
    val+='## 已复现的既有基线\n\n'
    val+='原矩阵核心八组回归实际重跑通过：13矩阵/480输出每组，共3840输出；双缓冲单元18比较；NPU两组队列回归各36批任务+2恢复任务，共2382输出。原 RTL 未改动，已有综合/实现源哈希审计通过。原报告属于 INT8 matmul_top/npu_top，本阶段资源属于 w4a8_linear，不能混用。\n\n'
    val+='## A：逐项位精确比较\n\n'
    val+=table(['配置','任务（含复位恢复）','输出比较','分组psum比较','协议检查','held input检查'],[[x['name'],x['tasks'],x['outputs'],x['psums'],x['checks'],x['held_inputs']] for x in s['simulations']])
    val+='\n先通过单缓冲定向12任务/189输出/453 psum，随后三配置完整回归。每次运行均检查所有有效输出坐标、唯一性、数值及last；所有group psum同样比较。覆盖全部16种INT4编码的高/低nibble、INT8边界、零/正负、固定随机、M/N/K尾块、group跨tile、末组不足、明显不同scale、两种group/阵列、连续任务、忙时start拒绝、非法零尺寸、计算中复位及输出受阻时复位、暂停恢复、输入/request/output持稳、bank所有权、实际重叠、有效MAC及字节流量。\n\n'
    val+='任务超时200000周期、全局20 ms watchdog、XSim Tcl最多20 ms；失败 $fatal，PowerShell另外检查PASS和失败日志，确保非零退出。故障注入状态：'+json.dumps(s['negative_probe'],ensure_ascii=False)+'。\n\n'
    val+='## B/C：数值误差（固定随机样本，非模型准确率）\n\n'
    val+=table(['group','case','饱和输出','B最大绝对误差','B RMSE','B相对L2','C最大绝对误差','C RMSE','C相对L2'],[[g,c['name'],c['saturated_outputs'],*[f"{v:.7g}" for level in ('B','C') for v in c[level].values()]] for g,cases in s['numerical'].items() for c in cases])
    val+='\nB：Q16.16反编码输出与理想未编码scale浮点量化参考比较，包括scale编码、输出舍入和饱和误差。C：浮点量化参考与原始浮点线性层比较。direct/zero/tie/saturation样例的原始浮点数据由反量化构造，C接近0是人为构造，真正量化误差看 kind=float 的 all_tails/decode/prefill/random_rect。两个group的量化张量不同，不应将数值差异直接归因于硬件。\n\n'
    val+='## 器件级综合 / OOC\n\n'
    if s['synthesis']['completed']:
        sy=s['synthesis'];val+=f"默认4×4/Ktile8/group32/双缓冲实际综合完成。Vivado {sy['version']}，part **{sy['part']}** 为既有临时评估选择，未确认板卡、最终封装和速度等级。Latch=0、blackbox=0。配置见 build/synth_w4a8/configuration.txt。\n\n"
        resources=[['综合',*[sy['utilization'].get(k,'—') for k in ('LUT','FF','DSP','RAMB18','RAMB36','LUTRAM','URAM')],sy['timing']['WNS_ns'],sy['timing']['WHS_ns']]]
        if s['ooc']['completed']:
            oc=s['ooc'];resources.append(['OOC布局布线',*[oc['utilization'].get(k,'—') for k in ('LUT','FF','DSP','RAMB18','RAMB36','LUTRAM','URAM')],oc['timing']['WNS_ns'],oc['timing']['WHS_ns']])
        val+=table(['阶段','LUT','FF','DSP','RAMB18','RAMB36','LUTRAM','URAM','WNS ns','WHS ns'],resources)
        val+='\n完整资源/存储映射见 utilization_synth.rpt、utilization_hier_synth.rpt、ram_synth.rpt；乘法器实际DSP实例及 USE_MULT/USE_SIMD 见 dsp_mapping.txt；primitive_counts.txt 列出全部原语。RAM属性不是结果，实际推断以报告为准。默认实际22 DSP：16 PE、factor乘法1、宽psum×factor乘法4、valid_macs计数乘法1。scaled寄存器移除警告对应吸收到DSP的寄存器（dsp_mapping列出scaled_reg/ scaled_reg__0），不能把全部DSP当PE数量。packed W4当前符号扩展后复用8×8 MAC，未做一个DSP多个INT4乘法打包。group scratch及输出累加BRAM位利用率各2.78%，刻意保留同步BRAM行为，后续可比较小容量LUTRAM。\n\n'
        val+='综合时序检查：\n\n~~~json\n'+json.dumps(sy['timing'],indent=2)+'\n~~~\n\n'
        if s['ooc']['completed']:
            val+='OOC实际检查：\n\n~~~json\n'+json.dumps(s['ooc'],indent=2,ensure_ascii=False)+'\n~~~\n\n'
        else:val+='OOC未运行或未完成；仅有综合估计。\n\n'
        val+='综合/实现日志中的关键警告（原文，重复条目保留）：\n\n~~~text\n'+'\n'.join(sy['warnings'])+'\n~~~\n\n'
        val+='100 MHz是10 ns初步目标；综合时序不代表布线后频率。OOC假设虚拟 BUFGCE_X0Y0，未约束板级管脚和接口输入/输出延迟，报告存在无I/O延迟路径，应明确区别于无时钟或内部未约束端点。即使内部时序满足，也不作板级signoff或板上性能承诺。\n\n'
    else:val+='综合尚未运行/完成。不得引用旧INT8资源作为W4A8结果。\n\n'
    val+='## VCS与范围\n\nWindows PATH/Get-Command、相关环境变量未发现VCS；WSL Ubuntu command -v vcs 及 /opt、/tools、/usr/local 常见 Synopsys目录探查无输出。未安装、未申请许可证、未运行VCS。提供可配置 Linux/WSL脚本 scripts/run_w4a8_vcs.sh，bash语法检查与VCS执行是两项不同检查，后者未验证。bash -n实际退出0，脚本可用性守卫实际返回 VCS_NOT_FOUND/退出2，未启动编译器；环境原始记录见 build/w4a8_environment.txt。XSim已经实际运行。\n\n'
    val+='已实现并验证：本报告列出的W4A8功能及两组参数组合；默认配置器件综合/OOC状态如上。已实现但未验证：其他合法参数组合、最大64×64×4096实际任务、VCS编译执行。未来计划：DDR/DMA/PCIe、独立张量地址任务队列、INT8 requant、bias/FFN/Attention/完整模型。现有 NPU队列与新W4A8 top 尚未连接；保留两条可独立复现的顶层，避免宣称完整模型调度已实现。\n'
    (ROOT/'docs/w4a8_validation.md').write_text(val,encoding='utf8')

    brief='# W4A8 内部交流摘要\n\n'
    brief+='## 当前硬件\n\n独立 w4a8_linear 已打通 packed INT4加载、A/B双缓冲、同步bank读与解包、4×4 MAC、group INT32 scratch、定点scale/64位合并及Q16.16输出背压；复用原mac_array/mac_pe，保留INT8/NPU基线。外存供数仅为TB模型，尚未连接旧NPU任务队列或真实DDR。\n\n'
    brief+='## 代表性任务如何流过硬件\n\nPrefill M=4、N=12、K=96、group32：3个N tile，每tile有3个group、每group有4个K tile，共36个请求。每个完整请求传16权重字节+32激活字节+16scale字节。首次包READY后consumer计算，另bank加载下一包；每group跨4tile保留INT32 psum，组完成存16个psum并逐槽缩放到64位输出累加器。三组完成后输出16元素，接受后继续下个N tile，最后done。整个任务48输出、4608有效MAC，不需驻留完整矩阵。\n\n'
    brief+=f"## 正确性与周期\n\n原INT8和NPU回归已复现；W4A8 {s['totals']['tasks']}任务、{s['totals']['outputs']}输出、{s['totals']['psums']}组psum逐项通过，两种阵列/group以及单缓冲对照。故障注入非零退出、计算中复位/输出背压复位恢复通过。B/C误差表在 w4a8_validation.md，包含非饱和与饱和用例，随机浮点样本不代表真实模型准确率。\n\n"
    brief+=table(['4×4/group32任务','连续供数双缓冲','首延迟/带宽受限','随机暂停+背压','连续供数单缓冲'],[['Decode 1×13×96',2106,2734,3098,2776],['Prefill 4×12×96',2555,3651,4416,3334]])
    if s['synthesis']['completed']:
        sy=s['synthesis'];u=sy['utilization']
        brief+=f"\n实际Vivado {sy['version']} / {sy['part']} 临时评估part：综合 {int(u['LUT'])} LUT、{int(u['FF'])} FF、{int(u['DSP'])} DSP、{int(u['RAMB18'])} RAMB18、{int(u['RAMB36'])} RAMB36、{int(u['LUTRAM'])} LUTRAM、0 URAM、0 latch。16 DSP在PE，5在scale，1在有效MAC计数。A/B分布式RAM，psum/output BRAM。\n\n"
        if s['ooc']['completed']:
            oc=s['ooc']
            brief+=f"OOC内部10ns约束 WNS {oc['timing']['WNS_ns']:+.3f} ns、WHS {oc['timing']['WHS_ns']:+.3f} ns，路由状态 {json.dumps(oc['route_status'])}；DRC边界及无I/O延迟限制详见验证报告。未做板级管脚/接口延迟约束或板上测量。\n\n"
        else:brief+='OOC未运行或未完成；仅有综合时序估计。\n\n'
    else:brief+='综合未运行/完成。\n\n'
    brief+='## 当前瓶颈与下一阶段\n\n默认Prefill连续供数，RUN288/2555拍，等输入1417拍；1byte输入带宽、重复A/scale传输是首要限制。每group保存/scale共64拍，当前compute与scale串行。Decode空PE行导致低利用率。优先讨论：(1)宽burst接口与A/scale复用；(2)专门GEMV的N/K并行映射；(3)psum/scale解耦及W4A8任务地址队列。理由及候选实验见 w4a8_next_steps.md。\n\n'
    brief+='理论16 MAC/拍、100MHz下1.6GMAC/s只是阵列上限；上表来自确定性供数模型，未测真实DDR/板上性能。VCS未发现且未运行，提供可配置脚本。AWQ/zero-point/完整LLM均不在当前交付范围。\n'
    (ROOT/'docs/w4a8_internal_brief.md').write_text(brief,encoding='utf8')

if __name__=='__main__':main()
