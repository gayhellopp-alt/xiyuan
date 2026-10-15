"""Integer-only requant contract, restoring-divider trace and independent oracle."""
import argparse
import json
import random
from pathlib import Path

MIN32 = -(1 << 31)
MAX32 = (1 << 31) - 1


def descriptor_error(group_size, k, group, length, scale, max_k=4096):
    if not 1 <= k <= max_k or not 0 <= group <= 65535:
        return 2
    start = group * group_size
    if start >= k or length != min(group_size, k - start) or length < 1:
        return 2
    if scale == 0:
        return 1
    if not 0 <= scale <= 65535:
        raise ValueError("scale is an unsigned16 encoding")
    return 0


def requant(t, scale, trace=False):
    if not MIN32 <= t <= MAX32 or not 1 <= scale <= 65535:
        raise ValueError("signed32 input and nonzero unsigned16 scale required")
    # abs in 33 bits, shift register in 32; minimum value has magnitude 2**31.
    magnitude = -t if t < 0 else t
    divisor = scale << 4
    dividend, quotient, remainder = magnitude, 0, 0
    states = []
    for step in range(32):
        trial = (remainder << 1) | (dividend >> 31)
        bit = int(trial >= divisor)
        remainder = trial - divisor if bit else trial
        dividend = (dividend << 1) & 0xFFFFFFFF
        quotient = ((quotient << 1) | bit) & 0xFFFFFFFF
        assert 0 <= remainder < divisor
        if trace:
            states.append(dict(step=step, dividend=dividend, quotient=quotient, remainder=remainder))
    assert (quotient, remainder) == divmod(magnitude, divisor)
    rounded = quotient + int(2 * remainder >= divisor)
    signed = -rounded if t < 0 else rounded
    saturated = signed < -128 or signed > 127
    q = max(-128, min(127, signed))
    # Independent nearest/ties-away oracle using a single floor operation.
    oracle_mag = (2 * magnitude + divisor) // (2 * divisor)
    oracle = max(-128, min(127, -oracle_mag if t < 0 else oracle_mag))
    assert q == oracle
    return dict(q=q, saturated=int(saturated), magnitude=magnitude, divisor=divisor,
                quotient=quotient, remainder=remainder, rounded=rounded, trace=states)


def make_cases(group_size):
    rng = random.Random(20261013 + group_size)
    cases = []
    def add(name, values, scale, group=0, k=None):
        k = group * group_size + len(values) if k is None else k
        assert descriptor_error(group_size, k, group, len(values), scale) == 0
        cases.append(dict(name=name, row=len(cases) % 65536, group=group, k=k,
                          length=len(values), scale=scale, values=values,
                          expected=[requant(t, scale) for t in values]))
    for s in (1, 2, 3, 17, 255, 256, 4096, 17001, 32768, 65535):
        d = s * 16
        vals = [0, MIN32, MAX32, -1, 1]
        for q in (0, 1, 126, 127, 128):
            for delta in (-1, 0, 1):
                t = q * d + d // 2 + delta
                for sign in (1, -1):
                    if MIN32 <= t * sign <= MAX32:
                        vals.append(t * sign)
        for i in range(0, len(vals), group_size):
            add(f"boundaries_s{s}_{i}", vals[i:i+group_size], s, group=2)
    for length in range(1, group_size + 1):
        add(f"tail_{length}", [rng.randint(MIN32, MAX32) for _ in range(length)],
            rng.randint(1, 65535), group=127)
    for i in range(150):
        s = rng.randint(1, 65535)
        # Include unsaturated random values as well as full signed32 stress.
        vals = [rng.randint(-200 * s * 16, 200 * s * 16) if i % 2 else
                rng.randint(MIN32, MAX32) for _ in range(rng.randint(1, group_size))]
        add(f"random_{i}", vals, s, group=i % 10)
    add("max_k_full", [0] * group_size, 4096, group=4096//group_size-1, k=(4096//group_size)*group_size)
    tail = 4096 % group_size or group_size
    add("max_k_tail", [MIN32, MAX32][:tail] + [0]*max(0, tail-2), 65535,
        group=(4096-1)//group_size, k=4096)
    return cases


def main():
    p = argparse.ArgumentParser()
    p.add_argument('--out', type=Path, default=Path('build/requant_vectors'))
    args = p.parse_args()
    args.out.mkdir(parents=True, exist_ok=True)
    checked = 0
    # All nonzero scale codes; ties, adjacent values, asymmetrical saturation,
    # and INT32_MIN/MAX. This validates the iterative reference against oracle.
    for s in range(1, 65536):
        d = 16*s
        for t in (MIN32, MAX32, d//2-1, d//2, -d//2, 127*d+d//2, -128*d-d//2):
            requant(t, s)
            checked += 1
    summary = dict(seed=20261013, scale_oracle_checks=checked, groups={})
    for g in (32, 12):
        cases = make_cases(g)
        tokens = [len(cases)]
        for c in cases:
            tokens += [c['row'], c['group'], c['k'], c['length'], c['scale']]
            for t, e in zip(c['values'], c['expected']):
                tokens += [t, e['q'], e['saturated']]
        (args.out/f'group{g}.txt').write_text('\n'.join(map(str, tokens))+'\n', encoding='ascii')
        (args.out/f'group{g}.json').write_text(json.dumps(cases, indent=2)+'\n', encoding='utf8')
        summary['groups'][str(g)] = dict(cases=len(cases), elements=sum(c['length'] for c in cases),
            saturated=sum(e['saturated'] for c in cases for e in c['expected']))
    summary['int32_min_trace'] = requant(MIN32, 65535, trace=True)
    (args.out/'reference_checks.json').write_text(json.dumps(summary, indent=2)+'\n', encoding='utf8')
    print('REQUANT_MODEL_PASS', json.dumps({k:v for k,v in summary.items() if k!='int32_min_trace'}))


if __name__ == '__main__':
    main()
