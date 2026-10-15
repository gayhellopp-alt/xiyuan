"""Audit current source identities and actual FFN simulation/VU9P evidence."""
import csv
import json
import re
import sys
sys.dont_write_bytecode=True
from summarize_requant import ROOT,sha,text,identity,utilization,timing,timing_checks
from reuse_traffic import traffic

def main():
    reference=json.loads(text(ROOT/'build/ffn_vectors/reference_checks.json'))
    assert int(text(ROOT/'build/ffn_vectors/model.log.exit_code.txt'))==0
    assert 'FFN_MODEL_PASS' in text(ROOT/'build/ffn_vectors/model.log')
    assert reference['silu_grid_checks']==65537 and reference['max_silu_abs_error']<0.00270
    delivery=dict(scope='Synthesizable SwiGLU coordinate bridge and TB three-projection FFN',
                  reference=reference,simulations=[],probes=[],eda=[])
    for name,marker in [('unit','SWIGLU'),('protocol','FFN_PROTOCOL'),('ffn32','FFN'),('ffn12','FFN')]:
        work=ROOT/f'build/sim_ffn_{name}';ident=identity(work)
        assert ident['capacity']==(0 if name=='unit' else 8 if name=='protocol' else 512)
        assert text(work/'PASS.txt').strip()=='PASS'
        for step in ('compile','elaborate','run'):assert int(text(work/f'{step}.log.exit_code.txt'))==0
        log=text(work/'run.log');assert not re.search(r'^Fatal:|CHECK_FAILED|_TIMEOUT|^ERROR:',log,re.M)
        match=re.search(r'^'+marker+r'_TESTS_PASS ([^\r\n]+)',log,re.M);assert match
        counters={k:int(v) for k,v in re.findall(r'(\w+)=(\d+)',match[1])}
        s=dict(name=name,identity=ident,counters=counters)
        if name=='unit':
            assert sha(work/'vectors.txt')==sha(ROOT/'build/ffn_vectors/unit.txt')
            assert counters['outputs']==2*reference['unit_cases']+7 and counters['aborts']==7 and counters['held']>500
        elif name=='protocol': assert counters['rejected']==6 and counters['outputs']==16
        else:
            g=int(name[3:]);g1=12 if g==32 else 32
            assert counters['group']==g and counters['tasks']==18 and counters['aborts']==8 and counters['held']>0
            assert counters['psums']>0 and counters['scaled']>0
            assert sha(work/'vectors.txt')==sha(ROOT/f'build/ffn_vectors/{name}.txt')
            cases=json.loads(text(ROOT/f'build/ffn_vectors/{name}.json'))
            rows=[{k:int(v) for k,v in r.items()} for r in csv.DictReader((work/'results.csv').open(encoding='ascii'))]
            expected=[(0,0),(0,1),(1,0),(1,1)]+[(1,1)]*8+[(i,mode) for i in range(2,5) for mode in (0,1)]
            assert [(r['case'],r['mode']) for r in rows]==expected
            for r in rows:
                c=cases[r['case']]
                assert (r['m'],r['k'],r['h'],r['n'])==(c['m'],c['k'],c['h'],c['n'])
                assert (r['gate'],r['up'],r['product'],r['qx'],r['y'],r['scales'])==(c['m']*c['h'],)*4+(c['m']*c['n'],c['m']*c['ng2'])
                assert (r['nonlinear_saturated'],r['scale_clipped'],r['quant_saturated'])==(sum(c['nonlinear_sat']),sum(c['clips']),sum(c['sats']))
                a=traffic(c['m'],c['h'],c['k'],4,4,8,g1,8,1,1,1)
                b=traffic(c['m'],c['n'],c['h'],4,4,8,g,8,1,1,1)
                assert r['weight_bytes']==2*a['weight_bytes']+b['weight_bytes']
                assert r['total_cycles']>=sum(r[k] for k in ('gate_cycles','up_cycles','bridge_cycles','down_cycles'))
            s['cycles']=rows;s['results_sha256']=sha(work/'results.csv')
            s['completed_totals']={k:sum(r[k] for r in rows) for k in ('gate','up','product','qx','y','scales','nonlinear_saturated','scale_clipped','quant_saturated','weight_bytes')}
            s['errors']=[{k:c[k] for k in ('id','kind','m','k','h','n','errors')} for c in cases]
        delivery['simulations'].append(s)
    for name,kind,marker in [('unit','negative','SWIGLU_CHECK_FAILED'),('ffn32','negative','FFN_CHECK_FAILED'),('ffn32','timeout','FFN_TIMEOUT')]:
        work=ROOT/f'build/sim_ffn_{name}_{kind}';identity(work)
        code=int(text(work/'observed_exit_code.txt'))
        assert code!=0 and marker in text(work/'run.log') and not (work/'PASS.txt').exists()
        delivery['probes'].append(dict(name=name,kind=kind,exit_code=code))
    if '--SimOnly' in sys.argv:
        print('FFN_SIMULATION_AUDIT_PASS',json.dumps([dict(name=s['name'],**s['counters']) for s in delivery['simulations']]))
        return
    for g in (32,12):
        work=ROOT/f'build/synth_ffn_g{g}';ident=identity(work);log=text(work/'synth_ffn.log')
        assert 'MAX_M=64 MAX_H=64 Quantizer_MAX_K=64' in text(work/'configuration.txt')
        assert int(text(work/'console.log.exit_code.txt'))==0
        assert re.search(r'^FFN_SYNTHESIS_PASS group='+str(g)+r'\b',log,re.M)
        assert not re.search(r'^ERROR:|^CRITICAL WARNING:',log,re.M)
        primitives={k:int(v) for k,v in re.findall(r'(\w+)=(\d+)',text(work/'primitive_counts.txt'))}
        assert primitives['Latch_count']==primitives['Blackbox_count']==0
        warnings=re.findall(r'^WARNING: (.*)$',log,re.M)
        (work/'warnings.txt').write_text('\n'.join(warnings)+'\n',encoding='utf8')
        e=dict(group_size=g,identity=ident,primitives=primitives,utilization=utilization(work/'utilization_synth.rpt'),
               timing=timing(work/'timing_synth.rpt'),timing_checks=timing_checks(work/'timing_synth.rpt'),
               warning_count=len(warnings),warning_codes=sorted(set(re.findall(r'^\[([^\]]+)\]','\n'.join(warnings),re.M))),
               ooc_completed=bool(re.search(r'^FFN_OOC_FINISHED',log,re.M)))
        # Gate RAM, up RAM, sigmoid ROM, and group buffer must remain physical memories.
        assert e['utilization']['RAMB18']+e['utilization']['RAMB36']==4,e['utilization']
        if e['ooc_completed']:
            e['ooc_utilization']=utilization(work/'utilization_ooc.rpt');e['ooc_timing']=timing(work/'timing_ooc.rpt')
            e['ooc_checks']=timing_checks(work/'timing_ooc.rpt')
            assert e['ooc_timing']['setup_failing_endpoints']==e['ooc_timing']['hold_failing_endpoints']==0,e['ooc_timing']
            route=text(work/'route_status_ooc.rpt');e['route_counts']={}
            for key,label in [('routable','routable nets'),('fully_routed','fully routed nets'),('errors','nets with routing errors'),('gaps','nets with explicit gaps')]:
                e['route_counts'][key]=int(re.search(r'# of '+label+r'\.+\s*:\s*(\d+)',route)[1])
            assert e['route_counts']['errors']==0 and e['route_counts']['routable']==e['route_counts']['fully_routed']
            assert not re.search(r'\|\s*[^|]+\|\s*(?:Error|Critical Warning)\s*\|',text(work/'drc_ooc.rpt'))
        delivery['eda'].append(e)
    paths=('rtl/vector/silu_sigmoid_lut.sv','rtl/vector/swiglu_element.sv','rtl/vector/ffn_bridge.sv',
           'model/vector/ffn_reference.py','tb/vector/tb_swiglu_element.sv','tb/vector/tb_ffn_protocol.sv',
           'tb/vector/tb_w4a8_ffn.sv','scripts/run_ffn.ps1','scripts/synth_ffn.tcl','scripts/summarize_ffn.py')
    delivery['files']={p:sha(ROOT/p) for p in paths}
    delivery['preserved_wave_sha256']=sha(ROOT/'rtl/w4a8_wave.sv');delivery['dynamic_delivery_sha256']=sha(ROOT/'build/dynamic_delivery.json')
    delivery['pass']=True
    (ROOT/'build/ffn_delivery.json').write_text(json.dumps(delivery,indent=2)+'\n',encoding='utf8')
    report(delivery)
    print('FFN_ARTIFACT_AUDIT_PASS',json.dumps(dict(simulations=[dict(name=s['name'],**s['counters']) for s in delivery['simulations']],eda=[{k:v for k,v in e.items() if k in ('group_size','utilization','ooc_timing')} for e in delivery['eda']])))

def report(d):
    lines=['# 小型 FFN：实际结构验证','',
           '依据当前源码SHA256、独立整数参考、XSim与Vivado产物生成。完整清单 [ffn_delivery.json](../build/ffn_delivery.json)。',
           '综合顶层ffn_bridge包含坐标组装RAM、SiLU ROM、标量乘法和动态requant；三个W4A8投影及packet供数/回填在TB组合验证。','',
           '| 自检 | 完整任务/输出 | 复位中止 | 检查项 |','|---|---:|---:|---:|']
    for s in d['simulations']:
        c=s['counters'];lines.append(f"| {s['name']} | {c.get('tasks',c.get('outputs'))} | {c.get('aborts',0)} | {c['checks']} |")
    lines+=['','日志gate/up/product/qx/y包含被复位任务的已检查前缀；完整任务总数单列在delivery.completed_totals。',
            '每配置18完整任务、8阶段复位恢复；group32/12，第一层group12/32；尾组/尾tile/M=1/M>1、零矩阵及故意饱和用例。',
            '逐阶段检查gate/up Q16.16、三次投影group psum和scale乘积、SiLU/乘法、qx/sx/absmax/clip/sat、最终down输出。',
            '协议自检覆盖6次非法描述符/坐标拒绝、8元素满容量、分支交错/反序坐标、两row尾组、每任务100拍持续背压。','',
            '| 探针 | 实际退出码 |','|---|---:|']
    for p in d['probes']:lines.append(f"| {p['name']}/{p['kind']} | {p['exit_code']} |")
    lines+=['','| group | 阶段 | LUT | FF | DSP | RAMB36 | RAMB18 | WNS ns | WHS ns |','|---|---|---:|---:|---:|---:|---:|---:|---:|']
    for e in d['eda']:
        stages=[('综合',e['utilization'],e['timing'])]+([('OOC',e['ooc_utilization'],e['ooc_timing'])] if e['ooc_completed'] else [])
        for stage,u,t in stages:lines.append(f"| {e['group_size']} | {stage} | "+' | '.join(str(u[k]) for k in ('LUT','FF','DSP','RAMB36','RAMB18'))+f" | {t['WNS_ns']} | {t['WHS_ns']} |")
        lines += ['',f"group{e['group_size']}：latch/blackbox=0，警告{e['warning_count']}条，代码 {', '.join(e['warning_codes'])}。实际RAM、层次资源、原文警告和时序见synth_ffn_g*/报告。"]
        if e['ooc_completed']:lines.append('路由 '+json.dumps(e['route_counts'])+'；setup/hold失败端点0。')
    lines+=['','Vivado2025.2，xcvu9p-flga2104-2L-e临时评估器件，10ns内部OOC，未指定板级pin/IO delay；不能视作板上频率证据。',
            f"SiLU网格{d['reference']['silu_grid_checks']}点，最大绝对误差{d['reference']['max_silu_abs_error']:.9g}，阈值0.00270，含±8截断边界。",'',
            '| group | case | 类型 | product最大误差 | product相对L2 | 最终最大误差 | 最终相对L2 |','|---|---:|---|---:|---:|---:|---:|']
    for s in d['simulations']:
        for c in s.get('errors',[]):
            a=c['errors']['product_vs_float'];b=c['errors']['final_vs_float']
            lines.append(f"| {s['name'][3:]} | {c['id']} | {c['kind']} | {a['max_abs']:.6g} | {a['relative_l2']:.6g} | {b['max_abs']:.6g} | {b['relative_l2']:.6g} |")
    lines+=['','正常、零和故意饱和用例分别报告；RTL对整数golden误差0。浮点链采用已编码的输入/权重scale，不代表真实模型精度。',
            '周期与中间状态计数保存在sim_ffn_ffn*/results.csv，本轮验证顺序执行，不要求重叠或性能收益。',
            '未运行VCS、综合网表、板上与真实模型；统一任务系统、外存写回、Attention/KV、RMSNorm/RoPE/Softmax及输出FIFO仍为后续范围。','']
    (ROOT/'docs/ffn_validation.md').write_text('\n'.join(lines),encoding='utf8')

if __name__=='__main__':main()
