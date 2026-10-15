"""Verify current-source dynamic/two-layer evidence and generate the report."""
import csv
import json
import re
import sys
from pathlib import Path
sys.dont_write_bytecode=True
from summarize_requant import ROOT,sha,text,identity,utilization,timing,timing_checks
from reuse_traffic import traffic


def main():
    reference=json.loads(text(ROOT/'build/dynamic_vectors/reference_checks.json'))
    delivery=dict(scope='Dynamic group requant and TB two-layer W4A8 connection',reference=reference,simulations=[],probes=[],eda=[],module_stats={})
    for name,g,prefix in [('module32',32,'DYNAMIC'),('module12',12,'DYNAMIC'),('chain32',32,'CHAIN'),('chain12',12,'CHAIN')]:
        work=ROOT/f'build/sim_dynamic_{name}';ident=identity(work)
        assert text(work/'PASS.txt').strip()=='PASS'
        for step in ('compile','elaborate','run'):
            assert int(text(work/(step+'.log.exit_code.txt')))==0
        log=text(work/'run.log');assert not re.search(r'^Fatal:|CHECK_FAILED|_TIMEOUT|^ERROR:',log,re.M)
        match=re.search(r'^'+prefix+r'_TESTS_PASS ([^\r\n]+)',log,re.M);assert match
        counters={k:int(v) for k,v in re.findall(r'(\w+)=(\d+)',match[1])}
        assert counters['group_size']==g
        rows=[{k:int(v) for k,v in r.items()} for r in csv.DictReader((work/'results.csv').open(encoding='ascii'))]
        vecname=('group' if prefix=='DYNAMIC' else 'chain')+str(g)
        assert sha(work/'vectors.txt')==sha(ROOT/f'build/dynamic_vectors/{vecname}.txt')
        cases=json.loads(text(ROOT/f'build/dynamic_vectors/{vecname}.json'))
        if prefix=='DYNAMIC':
            ref=reference['groups'][str(g)]
            assert counters['groups']==2*ref['cases'] and counters['outputs']==2*ref['elements']
            assert counters['rejects']==6 and counters['resets']==6 and counters['min_first']==70
            assert len(rows)==counters['groups']
            for r in rows:
                c=cases[r['case']]
                assert (r['length'],r['scale'],r['clipped'],r['absmax'],r['saturated'])==(c['length'],c['scale'],c['scale_clipped'],c['absmax'],int(any(c['sat'])))
                if r['mode']==0:assert r['cycles']==37*r['length']+34
            delivery['module_stats'][str(g)]=dict(scale_min=min(r['scale'] for r in rows),scale_max=max(r['scale'] for r in rows),clipped_groups=sum(r['clipped'] for r in rows),
                saturated_groups=sum(r['saturated'] for r in rows),saturated_elements=2*ref['saturated'],buffer_bits=g*32,
                complete_write_bytes=4*counters['outputs'],complete_read_bytes=4*counters['outputs'])
        else:
            assert counters['tasks']==16 and counters['aborts']==6 and counters['reordered']>0
            assert counters['p1']>0 and counters['p2']>0 and counters['scaled']>0
            assert len(rows)==16
            expected=[(0,0),(0,1),(1,0),(1,1)]+[(1,1)]*6+[(i,mode) for i in range(2,5) for mode in range(2)]
            assert [(r['case'],r['mode']) for r in rows]==expected
            for r in rows:
                c=cases[r['case']]
                assert (r['m'],r['k'],r['h'],r['n'])==(c['m'],c['k'],c['h'],c['n'])
                assert (r['y1'],r['qx'],r['y2'],r['scales'])==(c['m']*c['h'],c['m']*c['h'],c['m']*c['n'],c['m']*c['ng2'])
                assert r['clipped']==sum(c['clips']) and r['saturated']==sum(c['sats'])
                a=traffic(c['m'],c['h'],c['k'],4,4,8,c['g1'],8,1,1,1)
                b=traffic(c['m'],c['n'],c['h'],4,4,8,g,8,1,1,1)
                for key in ('weight_bytes','activation_bytes','scale_bytes','input_beats'):assert r[key]==a[key]+b[key],(name,key,r[key],a[key]+b[key])
                assert r['adapter_write_bytes']==4*c['m']*c['h']
                assert r['total_cycles']>=r['layer1_cycles']+r['dynamic_cycles']+r['layer2_cycles']
        completed_totals=({key:sum(r[key] for r in rows) for key in ('y1','qx','y2','scales','clipped','saturated','weight_bytes','activation_bytes','scale_bytes','input_beats','adapter_write_bytes')} if prefix=='CHAIN' else {})
        delivery['simulations'].append(dict(name=name,identity=ident,counters=counters,completed_totals=completed_totals,cycles=rows,vector_sha256=sha(work/'vectors.txt'),results_sha256=sha(work/'results.csv')))
    for name,kind,marker in [('module32','negative','DYNAMIC_CHECK_FAILED'),('chain32','negative','CHAIN_CHECK_FAILED'),('module32','timeout','DYNAMIC_TIMEOUT')]:
        work=ROOT/f'build/sim_dynamic_{name}_{kind}';identity(work)
        code=int(text(work/'observed_exit_code.txt'));assert code!=0 and marker in text(work/'run.log') and not (work/'PASS.txt').exists()
        delivery['probes'].append(dict(name=name,kind=kind,exit_code=code))
    for g in (32,12):
        work=ROOT/f'build/synth_dynamic_g{g}'
        if not (work/'primitive_counts.txt').exists():delivery['eda'].append(dict(group_size=g,synthesis_completed=False));continue
        ident=identity(work);log=text(work/'synth_dynamic.log')
        assert int(text(work/'console.log.exit_code.txt'))==0
        assert re.search(r'^DYNAMIC_SYNTHESIS_PASS group='+str(g)+r'\b',log,re.M) and not re.search(r'^ERROR:',log,re.M)
        primitives={k:int(v) for k,v in re.findall(r'(\w+)=(\d+)',text(work/'primitive_counts.txt'))}
        assert primitives['Latch_count']==0 and primitives['Blackbox_count']==0
        warnings=re.findall(r'^WARNING: (.*)$',log,re.M)
        (work/'warnings.txt').write_text('\n'.join(warnings)+'\n',encoding='utf8')
        e=dict(group_size=g,synthesis_completed=True,identity=ident,primitives=primitives,utilization=utilization(work/'utilization_synth.rpt'),timing=timing(work/'timing_synth.rpt'),timing_checks=timing_checks(work/'timing_synth.rpt'),
            warning_count=len(warnings),warning_codes=sorted(set(re.findall(r'^\[([^\]]+)\]','\n'.join(warnings),re.M))),ooc_completed=bool(re.search(r'^DYNAMIC_OOC_FINISHED group='+str(g)+r'\b',log,re.M)))
        assert e['utilization']['DSP']==0 and e['utilization']['RAMB18']+e['utilization']['RAMB36']==1
        if e['ooc_completed']:
            e['ooc_utilization']=utilization(work/'utilization_ooc.rpt');e['ooc_timing']=timing(work/'timing_ooc.rpt');e['ooc_checks']=timing_checks(work/'timing_ooc.rpt')
            assert e['ooc_timing']['setup_failing_endpoints']==0 and e['ooc_timing']['hold_failing_endpoints']==0
            route=text(work/'route_status_ooc.rpt');e['route_counts']={}
            for key,label in [('routable','routable nets'),('fully_routed','fully routed nets'),('errors','nets with routing errors'),('gaps','nets with explicit gaps')]:
                mt=re.search(r'# of '+label+r'\.+\s*:\s*(\d+)',route);assert mt;e['route_counts'][key]=int(mt[1])
            assert e['route_counts']['errors']==0 and e['route_counts']['routable']==e['route_counts']['fully_routed']
            e['drc']=text(work/'drc_ooc.rpt')
            assert not re.search(r'\|\s*[^|]+\|\s*(?:Error|Critical Warning)\s*\|',e['drc'])
        delivery['eda'].append(e)
    delivery['errors']={str(g):[{k:c[k] for k in ('id','kind','m','k','h','n','errors')} for c in json.loads(text(ROOT/f'build/dynamic_vectors/chain{g}.json'))] for g in (32,12)}
    delivery['files']={str(p.relative_to(ROOT)).replace('\\','/'):sha(p) for p in [ROOT/'rtl/vector/requant_dynamic.sv',ROOT/'model/vector/dynamic_reference.py',ROOT/'tb/vector/tb_requant_dynamic.sv',ROOT/'tb/vector/tb_w4a8_two_layer.sv',ROOT/'scripts/run_dynamic.ps1',ROOT/'scripts/synth_dynamic.tcl',ROOT/'scripts/summarize_dynamic.py']}
    delivery['external_scale_delivery_sha256']=sha(ROOT/'build/requant_delivery.json');delivery['w4a8_delivery_sha256']=sha(ROOT/'build/w4a8_wave_delivery.json');delivery['pass']=True
    (ROOT/'build/dynamic_delivery.json').write_text(json.dumps(delivery,indent=2)+'\n',encoding='utf8')
    lines=['# 动态 requant 与两层 W4A8：实际验证','', '由当前源码SHA256、Python参考、XSim、Vivado实际产物生成。完整清单见 [dynamic_delivery.json](../build/dynamic_delivery.json)。','',
        f"参考检查：{reference['scale_transition_checks']} 次scale编码边界；固定种子 {reference['seed']}。",'',
        '| 仿真 | 成功group/任务 | 输出qx | 自检项 | 活动复位/中止 |','|---|---:|---:|---:|---:|']
    for s in delivery['simulations']:
        c=s['counters'];qx=c['outputs'] if 'outputs' in c else s['completed_totals']['qx'];lines.append(f"| {s['name']} | {c.get('groups',c.get('tasks'))} | {qx} | {c['checks']} | {c.get('resets',c.get('aborts'))} |")
    lines+=['','模块连续时序：最后输入接受→第一输出接受70拍，后续输出间隔36拍，描述符接受→最后输出接受37×len+34拍；仿真逐组核对。',
        '两层使用不同第一/第二层group配置、多个组/尾组/尾tile、M=1与M>1、零组和scale超范围；实际按坐标存储后同步读组装，qx/sx与第二层独立sw逐项核对。',
        '检查两层Q16.16输出、每组INT32 psum/scale乘积、动态qx/sx/absmax/clip/sat；背压持稳、输入/array/post暂停、连续任务及六种阶段复位恢复。表中两层qx为完整任务输出，日志计数另外包含被复位任务已验证的前缀。',
        '第二层group32/12时第一层分别为group12/32，两个配置的总周期不能直接当作仅动态group尺寸的性能消融。','',
        '| module group | scale编码范围 | clipped组 | 饱和组 | 饱和元素 | Buffer有效bit | 完整任务RAM写/读字节各 |','|---|---|---:|---:|---:|---:|---:|']
    for g,s in delivery['module_stats'].items():lines.append(f"| {g} | {s['scale_min']}..{s['scale_max']} | {s['clipped_groups']} | {s['saturated_groups']} | {s['saturated_elements']} | {s['buffer_bits']} | {s['complete_write_bytes']} |")
    lines+=['',
        '| 探针 | 退出码 |','|---|---:|']
    for p in delivery['probes']:lines.append(f"| {p['name']}/{p['kind']} | {p['exit_code']} |")
    lines+=['','| group | 阶段 | LUT | FF | DSP | RAMB36 | RAMB18 | WNS ns | WHS ns |','|---|---|---:|---:|---:|---:|---:|---:|---:|']
    notes=[]
    for e in delivery['eda']:
        if not e['synthesis_completed']:lines.append(f"| {e['group_size']} | 未运行 | — | — | — | — | — | — | — |");continue
        stages=[('综合',e['utilization'],e['timing'])]+([('OOC',e['ooc_utilization'],e['ooc_timing'])] if e['ooc_completed'] else [])
        for stage,u,t in stages:lines.append(f"| {e['group_size']} | {stage} | "+' | '.join(str(u[k]) for k in ('LUT','FF','DSP','RAMB36','RAMB18'))+f" | {t['WNS_ns']} | {t['WHS_ns']} |")
        notes+=['',f"group{e['group_size']}：latch/blackbox=0；warning={e['warning_count']}，代码 {', '.join(e['warning_codes'])}。RAM细节见 ram_synth.rpt，警告原文见 warnings.txt。"]
        if e['ooc_completed']:notes.append('路由核对：'+json.dumps(e['route_counts'])+'；内部时序失败端点0。')
    lines+=notes+['','Vivado2025.2，xcvu9p-flga2104-2L-e临时评估part，10ns内部OOC，无板级管脚/IO delay；边界警告不视作板上成功证据。',
        '综合顶层仅requant_dynamic（包含原scalar和group RAM）；两层连接及512×32坐标存储适配器是TB验证，未宣称已经综合统一两层系统或DMA。','',
        '| 第二层group | case/kind | requant最大绝对误差 | requant相对L2 | 最终对浮点链最大绝对误差 | 最终相对L2 |','|---|---|---:|---:|---:|---:|']
    for g,cases in delivery['errors'].items():
        for c in cases:
            a=c['errors']['requant_vs_layer1'];b=c['errors']['final_vs_float_chain'];lines.append(f"| {g} | {c['id']}/{c['kind']} | {a['max_abs']:.6g} | {a['relative_l2']:.6g} | {b['max_abs']:.6g} | {b['relative_l2']:.6g} |")
    lines+=['','正常、零组和超范围饱和组分列；这是合成矩阵的已编码scale浮点链比较，不代表真实模型精度。layer1固定误差与layer2固定误差另保存在JSON。',
        '逐任务周期/两层packet字节/beat/中间流量见各sim_dynamic_chain*/results.csv。中间store每元素4字节写+4字节读；dynamic Buffer另4字节写+4字节读；qx每元素1字节，sx每row/group2字节。',
        '本动态/两层基线未运行VCS、综合网表或板上验证，也不含真实DMA/统一任务系统；新增FFN及有效槽独立交付请看当前C/E结构状态，输出FIFO仍待实现。','']
    (ROOT/'docs/dynamic_validation.md').write_text('\n'.join(lines),encoding='utf8')
    print('DYNAMIC_ARTIFACT_AUDIT_PASS',json.dumps(dict(simulations=[dict(name=s['name'],**s['counters']) for s in delivery['simulations']],eda=[{k:v for k,v in e.items() if k in ('group_size','utilization','ooc_timing')} for e in delivery['eda']])))


if __name__=='__main__':main()
