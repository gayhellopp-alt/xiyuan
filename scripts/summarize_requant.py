"""Audit live-source identities and actual requant logs; generate delivery evidence."""
import csv
import hashlib
import json
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def identity(work):
    data = json.loads((work/'source_inputs.json').read_text(encoding='utf-8-sig'))
    for path, expected in data['files'].items():
        assert sha(ROOT/path) == expected, f'Stale artifact: {work.name}: {path}'
    return data


def text(path):
    raw=path.read_bytes()
    return raw.decode('utf-16' if raw.startswith((b'\xff\xfe',b'\xfe\xff')) else 'utf-8-sig', errors='replace')


def utilization(path):
    report = text(path)
    result = {}
    for name, label in [('LUT','CLB LUTs'),('FF','CLB Registers'),('DSP','DSPs'),
                        ('RAMB36','RAMB36/FIFO'),('RAMB18','RAMB18'),('URAM','URAM'),
                        ('LUT_memory','LUT as Memory')]:
        match = re.search(r'\|\s*'+re.escape(label)+r'[^|]*\|\s*([\d,]+)', report)
        assert match, f'Missing utilization row {label}: {path}'
        result[name] = int(match[1].replace(',', ''))
    return result


def timing(path):
    report = text(path)
    match = re.search(r'WNS\(ns\).*?\n\s*-+.*?\n\s*([-\d.]+)\s+([-\d.]+)\s+(\d+)\s+(\d+)\s+([-\d.]+)\s+([-\d.]+)\s+(\d+)', report, re.S)
    assert match, f'Missing timing table: {path}'
    return dict(WNS_ns=float(match[1]), TNS_ns=float(match[2]),
                setup_failing_endpoints=int(match[3]), WHS_ns=float(match[5]),
                THS_ns=float(match[6]), hold_failing_endpoints=int(match[7]))


def timing_checks(path):
    report=text(path)
    counts={k:int(v) for k,v in re.findall(r'checking (\w+) \((\d+)\)', report)}
    for key in ('no_clock','unconstrained_internal_endpoints','loops','latch_loops'):
        assert key in counts and counts[key]==0, f'{key}: {path}'
    return counts


def main():
    summary = dict(scope='External-scale Q16.16 to INT8; independent group stream',
                   reference=json.loads(text(ROOT/'build/requant_vectors/reference_checks.json')),
                   simulations=[], negative_probes=[], eda=[])
    for g in (32, 12):
        work = ROOT/f'build/sim_requant_g{g}'
        ident = identity(work)
        assert (work/'PASS.txt').exists()
        log = text(work/'run.log')
        assert not re.search(r'^Fatal:|^ERROR:|REQUANT_CHECK_FAILED|REQUANT_TIMEOUT', log, re.M)
        match = re.search(r'REQUANT_TESTS_PASS ([^\r\n]+)', log)
        assert match
        counters = {k:int(v) for k,v in re.findall(r'(\w+)=(\d+)', match[1])}
        assert counters['group_size']==g
        ref = summary['reference']['groups'][str(g)]
        assert counters['groups'] == 2*ref['cases']+1
        assert counters['outputs'] == 2*ref['elements']+1
        assert counters['rejects'] == 9 and counters['resets'] == 8
        assert counters['min_latency'] == 34 and counters['min_ii'] == 35
        rows = list(csv.DictReader((work/'results.csv').open(encoding='ascii')))
        assert len(rows) == counters['groups']
        for row in rows:
            length = int(row['length'])
            if row['mode'] == '0':
                assert int(row['output_span']) == 35*length-1
        expected_vec = ROOT/f'build/requant_vectors/group{g}.txt'
        assert sha(work/'vectors.txt') == sha(expected_vec)
        summary['simulations'].append(dict(group_size=g, counters=counters, identity=ident,
            vectors_sha256=sha(expected_vec), results_sha256=sha(work/'results.csv')))
    for kind, marker in [('negative','REQUANT_CHECK_FAILED'),('timeout','REQUANT_TIMEOUT')]:
        work=ROOT/f'build/sim_requant_g32_{kind}'
        identity(work)
        code=int(text(work/'observed_exit_code.txt').strip())
        assert code != 0 and marker in text(work/'run.log')
        assert not (work/'PASS.txt').exists()
        summary['negative_probes'].append(dict(kind=kind, exit_code=code))
    for g in (32,12):
        work=ROOT/f'build/synth_requant_g{g}'
        if not (work/'primitive_counts.txt').exists():
            summary['eda'].append(dict(group_size=g, synthesis_completed=False))
            continue
        ident=identity(work)
        log=text(work/'synth_requant.log')
        assert re.search(r'^REQUANT_SYNTHESIS_PASS group='+str(g)+r'\b',log,re.M) and not re.search(r'^ERROR:',log,re.M)
        primitives={k:int(v) for k,v in re.findall(r'([\w]+)=(\d+)',text(work/'primitive_counts.txt'))}
        assert primitives['Latch_count']==0 and primitives['Blackbox_count']==0
        warnings=re.findall(r'^WARNING: (.*)$',log,re.M)
        (work/'warnings.txt').write_text('\n'.join(warnings)+'\n',encoding='utf8')
        eda=dict(group_size=g, synthesis_completed=True, part='xcvu9p-flga2104-2L-e',
            identity=ident, utilization=utilization(work/'utilization_synth.rpt'),
            timing=timing(work/'timing_synth.rpt'), primitives=primitives,
            warning_count=len(warnings), warning_codes=sorted(set(re.findall(r'^\[([^\]]+)\]', '\n'.join(warnings),re.M))),
            ooc_completed=bool(re.search(r'^REQUANT_OOC_FINISHED group='+str(g)+r'\b',log,re.M)))
        eda['timing_checks']=timing_checks(work/'timing_synth.rpt')
        assert eda['utilization']['FF']==primitives.get('FDRE',0)
        assert eda['utilization']['DSP']==primitives.get('DSP48E2',0)
        assert eda['utilization']['RAMB36']==primitives.get('RAMB36E2',0)
        assert eda['utilization']['RAMB18']==primitives.get('RAMB18E2',0)
        assert eda['utilization']['LUT_memory']==0
        if eda['ooc_completed']:
            eda['ooc_utilization']=utilization(work/'utilization_ooc.rpt')
            eda['ooc_timing']=timing(work/'timing_ooc.rpt')
            eda['internal_target_met']=eda['ooc_timing']['WNS_ns']>=0 and eda['ooc_timing']['WHS_ns']>=0
            eda['ooc_timing_checks']=timing_checks(work/'timing_ooc.rpt')
            assert eda['ooc_timing']['setup_failing_endpoints']==0 and eda['ooc_timing']['hold_failing_endpoints']==0
            eda['route_status']=text(work/'route_status_ooc.rpt')
            route={}
            for key,label in [('routable_nets','routable nets'),('fully_routed_nets','fully routed nets'),
                              ('routing_errors','nets with routing errors'),('explicit_gaps','nets with explicit gaps')]:
                match=re.search(r'# of '+label+r'\.+\s*:\s*(\d+)',eda['route_status'])
                assert match, f'Missing route status: {label}'
                route[key]=int(match[1])
            assert route['routable_nets']==route['fully_routed_nets'] and route['routing_errors']==0
            eda['route_counts']=route
            eda['drc']=text(work/'drc_ooc.rpt')
            assert re.search(r'Checks found:\s*0\b',eda['drc']), 'Review nonempty OOC DRC report'
        summary['eda'].append(eda)
    summary['pass']=True
    # Preserved baseline is evidence only when a fresh run is requested and its
    # own audit succeeds; retain the complete existing delivery hash here.
    baseline=ROOT/'build/w4a8_wave_delivery.json'
    summary['preserved_w4a8_delivery_sha256']=sha(baseline) if baseline.exists() else None
    summary['files']={str(p.relative_to(ROOT)).replace('\\','/'):sha(p) for folder in ('rtl/vector','tb/vector','model/vector') for p in (ROOT/folder).glob('*') if p.is_file()}
    for p in ('scripts/run_requant.ps1','scripts/synth_requant.tcl','scripts/summarize_requant.py'):
        summary['files'][p]=sha(ROOT/p)
    (ROOT/'build/requant_delivery.json').write_text(json.dumps(summary,indent=2)+'\n',encoding='utf8')
    lines=['# Requant 最小基线：实际工具验证','',
        '本报告由 scripts/summarize_requant.py 根据当前源码身份、参考模型、XSim 和 Vivado 日志生成。',
        '数值与接口见 [数值合同](requant_numerics.md)、[接口](requant_interface.md)。','',
        f"参考模型已对所有非零 scale 编码完成 {summary['reference']['scale_oracle_checks']} 次逐位除法/独立整数 oracle 比较。",'',
        '| GROUP_SIZE | 成功组 | 输出 | 自检项 | 拒绝描述符 | 复位 | 背压持稳检查 | 最小输出接受延迟 | 最小 II |',
        '|---|---:|---:|---:|---:|---:|---:|---:|---:|']
    for sim in summary['simulations']:
        c=sim['counters'];lines.append('| '+' | '.join(str(c[k]) for k in ('group_size','groups','outputs','checks','rejects','resets','held_checks','min_latency','min_ii'))+' |')
    lines += ['', '无阻塞时 input handshake 后第 33 拍产生 out_valid，第 34 拍最早接受输出；同组输入 II=35。',
        '包含整数边界、半值及相邻值、非二次幂 scale、最小 scale、全 scale 范围随机、group32/12 与尾组、最大 K 描述符、输入暂停、长输出背压、连续组、忙时描述符、活动复位。',
        '每元素 100 拍等待检查和全局 20ms watchdog；独立 golden 错误与 watchdog 探针均实际非零退出。','',
        '| 探针 | 退出码 |','|---|---:|']
    for p in summary['negative_probes']:lines.append(f"| {p['kind']} | {p['exit_code']} |")
    lines += ['', '| GROUP_SIZE | 阶段 | LUT | FF | DSP | RAMB36 | RAMB18 | URAM | WNS/ns | WHS/ns |','|---|---|---:|---:|---:|---:|---:|---:|---:|---:|']
    eda_notes=[]
    for e in summary['eda']:
        if not e['synthesis_completed']:
            lines.append(f"| {e['group_size']} | 未运行 | — | — | — | — | — | — | — | — |")
            continue
        for stage,u,t in [('综合',e['utilization'],e['timing'])]+([('OOC',e['ooc_utilization'],e['ooc_timing'])] if e['ooc_completed'] else []):
            lines.append(f"| {e['group_size']} | {stage} | "+' | '.join(str(u[k]) for k in ('LUT','FF','DSP','RAMB36','RAMB18','URAM'))+f" | {t['WNS_ns']} | {t['WHS_ns']} |")
        eda_notes += ['',f"GROUP_SIZE={e['group_size']}：latch/blackbox=0；警告 {e['warning_count']} 条，代码：{', '.join(e['warning_codes'])}。",
            f"全部原文保存在 build/synth_requant_g{e['group_size']}/warnings.txt、drc_*.rpt 和 check_timing_*.rpt。"]
        if e['ooc_completed']:
            r=e['route_counts'];eda_notes += [f"内部可路由网络 {r['fully_routed_nets']}/{r['routable_nets']} 已完成，routing errors={r['routing_errors']}，显式 OOC 边界 gap={r['explicit_gaps']}；DRC Checks found=0。"]
    lines += eda_notes
    lines += ['', '器件为本机核验可用的 xcvu9p-flga2104-2L-e，Vivado 2025.2，10ns 内部 OOC 时钟；板卡未确认，无 I/O delay/管脚约束。',
        '外部端口无 delay 与 OOC 边界路由警告需要与内部 setup/hold 分开理解，结果不证明板上频率。',
        '新模块不含 group RAM；仅单标量寄存器及逐位除法状态，DSP/RAM 映射以上述实测为准。',
        '源码 SHA256、实际命令、逐组周期 CSV、primitive 数量、完整报告与 DCP 均位于 build；交付清单为 [requant_delivery.json](../build/requant_delivery.json)。',
        '未运行：VCS、综合网表仿真、板上验证。未实现：动态 scale、tile 坐标组装、两层串联、FFN、真实 DMA/写回。','']
    (ROOT/'docs/requant_validation.md').write_text('\n'.join(lines),encoding='utf8')
    print('REQUANT_ARTIFACT_AUDIT_PASS',json.dumps(dict(simulations=[s['counters'] for s in summary['simulations']],eda=[{k:v for k,v in e.items() if k in ('group_size','utilization','ooc_timing','internal_target_met')} for e in summary['eda']])))


if __name__=='__main__':
    main()
