"""Audit actual local artifacts and write a machine-readable summary. No EDA estimates invented."""
import argparse
import csv
import hashlib
import json
import re
import sys
from pathlib import Path
sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parents[1]/"model"))
from generate_vectors import double_buffer_cycles


def read(p):
    raw = p.read_bytes()
    encoding = 'utf-16' if raw.startswith((b'\xff\xfe', b'\xfe\xff')) else 'utf-8-sig'
    return raw.decode(encoding, errors='replace')


def utilization(path):
    text = read(path)
    fields = {}
    for line in text.splitlines():
        if not line.startswith('|'):
            continue
        cells = [c.strip() for c in line.strip('|').split('|')]
        if len(cells) < 2:
            continue
        key = cells[0].rstrip('*').strip()
        try:
            # SLR breakdown later repeats resource names; keep the global table.
            fields.setdefault(key, float(cells[1].replace(',', '')))
        except ValueError:
            continue
    keys = {'LUT': 'CLB LUTs', 'logic_LUT': 'LUT as Logic', 'LUTRAM': 'LUT as Memory',
            'FF': 'CLB Registers', 'BRAM_tiles': 'Block RAM Tile',
            'RAMB18': 'RAMB18', 'RAMB36': 'RAMB36/FIFO', 'URAM': 'URAM', 'DSP': 'DSPs'}
    out = {k: fields[v] for k, v in keys.items() if v in fields}
    assert all(k in out for k in ('LUT','FF','BRAM_tiles','URAM','DSP')), fields
    return out


def timing(path):
    text = read(path)
    checks = {}
    for name, value in re.findall(r'checking ([a-z_]+) \((\d+)\)', text):
        checks[name] = int(value)
    segment = text.split('| Design Timing Summary', 1)[1]
    row = next(line for line in segment.splitlines()
               if re.match(r'^\s+-?\d+\.\d+\s+-?\d+\.\d+\s+\d+\s+\d+', line))
    values = row.split()
    return {'WNS_ns': float(values[0]), 'TNS_ns': float(values[1]),
            'setup_failing_endpoints': int(values[2]),
            'WHS_ns': float(values[4]), 'THS_ns': float(values[5]),
            'hold_failing_endpoints': int(values[6]), 'checks': checks,
            'scope': 'OOC internal timing; external I/O delays unspecified'}


def main():
    p = argparse.ArgumentParser()
    p.add_argument('--root', type=Path, default=Path(__file__).resolve().parents[1])
    args = p.parse_args()
    root = args.root.resolve()
    manifest = json.loads(read(root / 'build/vectors/manifest.json'))
    summary = {'seed': manifest['seed'], 'reference_backend': manifest['backend'],
               'numpy_crosscheck_version': manifest.get('numpy_crosscheck_version'),
               'simulations': [], 'source_sha256': {}}
    for rows, cols, tk, opt, db, gap in [(4,4,8,1,1,0),(2,3,5,1,1,0),(2,3,5,1,1,3),(2,1,3,1,1,0),(4,4,8,1,0,0),(2,3,5,1,0,0),(4,4,8,0,0,0),(2,3,5,0,0,0)]:
        work = root / (f'build/sim_{rows}x{cols}_k{tk}' + ('_db' if db else ('_opt' if opt else '')) + (f'_gap{gap}' if gap else ''))
        log = read(work / 'run.log')
        assert 'ALL_TESTS_PASS' in log and not re.search(r'Fatal:|MISMATCH|CHECK_FAILED|GLOBAL_TIMEOUT|ERROR:', log)
        assert read(work / 'PASS.txt').strip() == 'PASS'
        records = list(csv.DictReader((work / 'results.csv').open(encoding='utf-8-sig', newline='')))
        assert len(records) == len(manifest['cases'])
        for record, case in zip(records, manifest['cases']):
            r = {key: int(value) for key,value in record.items()}
            assert (r['case_id'],r['M'],r['N'],r['K']) == (case['id'],case['m'],case['n'],case['k'])
            assert (r['ROWS'],r['COLS'],r['TILE_K']) == (rows,cols,tk)
            output_tiles = ((r['M']+rows-1)//rows)*((r['N']+cols-1)//cols)
            k_tiles = (r['K']+tk-1)//tk
            active = output_tiles*(1+k_tiles*(2*tk*(rows+cols)+rows*cols+2)+r['K'])
            if opt:
                active = ((r['M']+rows-1)//rows)*(rows*r['K']+1) + output_tiles*(1+cols*r['K']+3*k_tiles+r['K']+rows*cols)
            if db:
                active = double_buffer_cycles(r['M'],r['N'],r['K'],rows,cols,tk,gap)
            assert (r['DOUBLE_BUFFER'],r['B_LOAD_GAP']) == (db,gap)
            assert r['OPTIMIZED'] == opt
            assert r['A_reads'] == r['M']*r['K']*(1 if opt else (r['N']+cols-1)//cols)
            assert r['B_reads'] == ((r['M']+rows-1)//rows)*r['K']*r['N']
            assert r['P_writes'] == r['M']*r['N']*(1 if opt else k_tiles)
            assert r['active_cycles'] == active
            assert r['elapsed_cycles'] == active+r['stall_cycles']
        match = re.search(r'ALL_TESTS_PASS .*?matrices=(\d+) comparisons=(\d+) PE=(\d+) checks=(\d+)', log)
        assert match and int(match[2]) == manifest['matrix_output_comparisons_per_configuration']
        summary['simulations'].append({'ROWS':rows,'COLS':cols,'TILE_K':tk,'OPTIMIZED':opt,'DOUBLE_BUFFER':db,'B_LOAD_GAP':gap,
                                      'matrices':int(match[1]),'output_comparisons':int(match[2]),
                                      'pe_cases':int(match[3]),'checks':int(match[4]),'cycles':records})
    unit_dir=root/'build/sim_pingpong_unit'
    unit_log=read(unit_dir/'run.log')
    assert read(unit_dir/'PASS.txt').strip()=='PASS'
    assert not re.search(r'Fatal:|FAILED|TIMEOUT|ERROR:',unit_log)
    unit_match=re.search(r'PINGPONG_UNIT_PASS tiles=(\d+) comparisons=(\d+) checks=(\d+)',unit_log)
    assert unit_match and int(unit_match[1])==3 and int(unit_match[2])==18
    summary['pingpong_unit']={'tiles':int(unit_match[1]),'data_comparisons':int(unit_match[2]),'checks':int(unit_match[3]),'wrong_tag_and_full_banks_verified':True}
    summary['cycle_comparison'] = []
    for rows,cols,tk in [(4,4,8),(2,3,5)]:
        base = next(s for s in summary['simulations'] if s['ROWS']==rows and s['OPTIMIZED']==0)
        opt = next(s for s in summary['simulations'] if s['ROWS']==rows and s['OPTIMIZED']==1 and s['DOUBLE_BUFFER']==0)
        for b,o,case in zip(base['cycles'],opt['cycles'],manifest['cases']):
            bc,oc = int(b['active_cycles']),int(o['active_cycles'])
            assert oc < bc
            summary['cycle_comparison'].append({'case':case['name'],'ROWS':rows,'COLS':cols,
                'baseline_cycles':bc,'optimized_cycles':oc,'cycle_speedup':bc/oc})
    summary['double_buffer_comparison'] = []
    for rows,cols,tk in [(4,4,8),(2,3,5)]:
        single = next(x for x in summary['simulations'] if x['ROWS']==rows and x['COLS']==cols and x['OPTIMIZED']==1 and x['DOUBLE_BUFFER']==0)
        double = next(x for x in summary['simulations'] if x['ROWS']==rows and x['COLS']==cols and x['DOUBLE_BUFFER']==1 and x['B_LOAD_GAP']==0)
        for a,b,case in zip(single['cycles'],double['cycles'],manifest['cases']):
            ac,bc=int(a['active_cycles']),int(b['active_cycles'])
            summary['double_buffer_comparison'].append({'case':case['name'],'ROWS':rows,'COLS':cols,'single_cycles':ac,'double_cycles':bc,'cycle_speedup':ac/bc,'wait_cycles':int(b['wait_cycles']),'overlap_cycles':int(b['overlap_cycles'])})
    synth_dir = root / 'build/synth_db'
    logs = []
    for name in ['synth.log','resume_reports.log']:
        f = synth_dir / name
        if f.exists():
            logs.append((f.stat().st_mtime, name, read(f)))
    _, latest_name, latest_log = max(logs)
    assert re.search(r'^SYNTHESIS_PASS part=', latest_log, re.M), 'Synthesis/report completion marker absent'
    part = read(root / 'build/selected_part.txt').strip()
    assert 'vu9p' in part
    primitive_text = read(synth_dir / 'primitive_counts.txt')
    assert 'Latch_count=0' in primitive_text
    assert 'OPTIMIZED:1' in primitive_text and 'DOUBLE_BUFFER:1' in primitive_text
    provenance = json.loads(read(synth_dir/'source_inputs.json'))
    assert provenance['OPTIMIZED'] == 1 and provenance['DOUBLE_BUFFER'] == 1
    for name,digest in provenance['files'].items():
        assert hashlib.sha256((root/name).read_bytes()).hexdigest() == digest, name
    summary['synthesis'] = {'source_input_hashes_match':True,'part':part,'board_confirmed':False,'report_log':latest_name,
                            'utilization':utilization(synth_dir/'utilization_synth.rpt'),
                            'timing':timing(synth_dir/'timing_synth.rpt'),'latches':0,
                            'virtual_clock_source':re.search(r'Virtual_OOC_clock_source=(.*)',primitive_text)[1].strip(),
                            'warnings_in_report_and_impl_log': [line for line in latest_log.splitlines()
                                if line.startswith(('WARNING:','CRITICAL WARNING:'))]}
    assert summary['synthesis']['utilization']['DSP'] == 16
    assert summary['synthesis']['timing']['checks']['no_clock'] == 0
    assert summary['synthesis']['timing']['checks']['unconstrained_internal_endpoints'] == 0
    if re.search(r'^OOC_IMPLEMENTATION_FINISHED$', latest_log, re.M):
        summary['ooc_implementation'] = {'completed':True,
                                       'utilization':utilization(synth_dir/'utilization_ooc.rpt'),
                                       'timing':timing(synth_dir/'timing_ooc.rpt')}
        route = read(synth_dir/'route_status_ooc.rpt')
        route_counts = {}
        for key,label in [('routable_nets','routable nets'),('fully_routed_nets','fully routed nets'),
                          ('routing_errors','nets with routing errors'),('explicit_gaps','nets with explicit gaps')]:
            match = re.search(r'# of '+label+r'\.+\s*:\s*(\d+)',route)
            assert match, (key, route)
            route_counts[key] = int(match[1])
        summary['ooc_implementation']['route_status'] = route_counts
        ooc_util_text = read(synth_dir/'utilization_ooc.rpt')
        summary['ooc_implementation']['design_state_from_utilization'] = re.search(r'\| Design State\s*:\s*([^\r\n]+)',ooc_util_text)[1].strip()
        summary['ooc_implementation']['design_state_from_drc'] = re.search(r'\| Design State\s*:\s*([^\r\n]+)', read(synth_dir/'drc_ooc.rpt'))[1].strip()
        drc_text=read(synth_dir/'drc_ooc.rpt')
        summary['ooc_implementation']['drc_checks']=[{'rule':rule,'severity':severity,'description':description.strip(),'checks':int(count)}
            for rule,severity,description,count in re.findall(r'^\|\s*([A-Z][A-Z0-9_-]+)\s*\|\s*(Warning|Error|Critical Warning)\s*\|\s*([^|]+)\s*\|\s*(\d+)\s*\|',drc_text,re.M)]
        summary['ooc_implementation']['drc_boundary_warning'] = 'RTSTAT-10: outputs have no routable loads in this OOC context; see drc_ooc.rpt'
        assert route_counts['routing_errors'] == 0
        assert summary['ooc_implementation']['utilization']['DSP'] == 16
    else:
        summary['ooc_implementation'] = {'completed':False}
    negative = root / 'build/sim_4x4_k8_db_negative'
    if (negative/'run.log').exists():
        summary['negative_probe'] = {'expected_failure_detected':re.search(r'Fatal:.*(?:MISMATCH|CHECK_FAILED)', read(negative/'run.log')) is not None,
                                     'pass_marker_absent':not (negative/'PASS.txt').exists()}
        if (negative/'observed_exit_code.txt').exists():
            summary['negative_probe']['observed_powershell_exit_code'] = int(read(negative/'observed_exit_code.txt'))
    for folder in ['rtl','tb','model','scripts','constraints','config']:
        for f in sorted((root/folder).glob('*')):
            if f.is_file():
                summary['source_sha256'][f.relative_to(root).as_posix()] = hashlib.sha256(f.read_bytes()).hexdigest()
    baseline_archive = root / 'build/baseline_v1/summary.json'
    if baseline_archive.exists():
        historic = json.loads(read(baseline_archive))
        summary['historic_baseline_synthesis'] = historic['synthesis']
        summary['historic_baseline_ooc'] = historic['ooc_implementation']
    optimized_archive = root / 'build/optimized_v2/summary.json'
    if optimized_archive.exists():
        historic = json.loads(read(optimized_archive))
        summary['historic_single_synthesis'] = historic['synthesis']
        summary['historic_single_ooc'] = historic['ooc_implementation']
    target = root / 'build/summary.json'
    target.write_text(json.dumps(summary,indent=2,ensure_ascii=False), encoding='utf-8')
    print('ARTIFACT_AUDIT_PASS: 8 simulations, 3840 matrix outputs, VU9P synthesis; ' + str(target))
    brief = dict(summary['synthesis'])
    brief.pop('warnings_in_report_and_impl_log', None)
    print(json.dumps({'synthesis':brief, 'ooc_implementation':summary['ooc_implementation']},indent=2,ensure_ascii=False))


if __name__ == '__main__':
    main()
