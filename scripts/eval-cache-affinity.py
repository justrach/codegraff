#!/usr/bin/env python3
"""Paired live cache-affinity probe. Runs only when explicitly invoked.

Both binaries must contain identical changes except cache affinity. This runner
records immutable copies/hashes; it cannot establish their source equivalence.
Each arm warms a primary checkout then measures a fresh linked checkout. Arms
have separate repositories, counterbalanced execution order, identical prompts,
and isolated credentials/HOME. A fresh routing key is not proof of a cold server
cache, especially for providers that ignore the routing key.
"""
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import shutil
import signal
import statistics
import subprocess
import sys
import time

HELPERS = Path(__file__).resolve().parents[1] / 'graff-evals' / 'measurement.py'
spec = importlib.util.spec_from_file_location('measurement', HELPERS)
measurement = importlib.util.module_from_spec(spec)
spec.loader.exec_module(measurement)
ANSWER = 'CACHE_OK'


def digest(path):
    h = hashlib.sha256()
    with open(path, 'rb') as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b''):
            h.update(chunk)
    return h.hexdigest()


def write_json(path, data):
    path.write_text(json.dumps(data, indent=2, allow_nan=False) + '\n')
    path.chmod(0o600)


def git(args, env):
    p = subprocess.run(['git', *args], env=env, capture_output=True, text=True, timeout=30)
    if p.returncode:
        raise RuntimeError('Git fixture setup failed: ' + p.stderr[-2000:])


def fixture(root, env):
    primary, linked = root / 'primary', root / 'linked'
    git(['init', '-q', str(primary)], env)
    git(['-C', str(primary), '-c', 'user.name=Cache fixture', '-c',
         'user.email=fixture@example.invalid', 'commit', '-q', '--allow-empty', '-m', 'fixture'], env)
    git(['-C', str(primary), 'worktree', 'add', '-q', '--detach', str(linked)], env)
    return primary, linked


def prompt_for(repeat):
    # >2,000 whitespace words plus numbers: well above common cache thresholds.
    # The task and bytes are identical across the two arms. These records are
    # synthetic data, not instructions; no workspace or account material enters.
    records = '\n'.join(f'Record {i:04d}: amber cedar quartz willow; quantity {i % 97}; status unchanged.'
                        for i in range(320))
    return (f'Synthetic cache routing fixture, paired repetition {repeat}.\n'
            'Read the reference records below. Do not use tools or inspect files.\n'
            'Reply with exactly CACHE_OK and nothing else. No explanation or formatting.\n'
            '<reference-data>\n' + records + '\n</reference-data>\n'
            'The required complete answer is exactly CACHE_OK.\n')


def parse_trace(cwd):
    rows, malformed = [], 0
    for path in sorted((cwd / '.graff' / 'traces').glob('*.jsonl')):
        for line in path.read_text(errors='replace').splitlines():
            try:
                row = json.loads(line)
            except ValueError:
                malformed += 1
                continue
            if isinstance(row, dict):
                rows.append(row)
    return rows, malformed


def validate(stdout, stderr, rows, model, code, timed_out):
    usage = measurement.graff_usage(stderr)
    final_lines = [measurement.ANSI.sub('', line).strip() for line in stderr.splitlines()
                   if measurement.FOOTER.fullmatch(measurement.ANSI.sub('', line).strip())]
    writes_known = bool(final_lines and measurement.FOOTER.fullmatch(final_lines[-1]).group(4) is not None)
    if usage and not writes_known:
        usage['writes'] = None
    issues = []
    if code != 0 or timed_out:
        issues.append('process_failed_or_timed_out')
    if measurement.ANSI.sub('', stdout).strip() != ANSWER:
        issues.append('answer_not_exact')
    api = [r for r in rows if r.get('ev') == 'api']
    roots = [r for r in api if r.get('agent') == 'main']
    identities = sorted({(r['provider'], r['model']) for r in rows
                         if isinstance(r.get('provider'), str) and isinstance(r.get('model'), str)})
    if not roots or any(r.get('model') != model for r in roots):
        issues.append('missing_or_wrong_root_model_trace')
    if not identities or any(provider != 'codegraff' or actual != model for provider, actual in identities):
        issues.append('missing_or_wrong_provider_model_trace')
    normalized = None
    if not usage:
        issues.append('missing_usage')
    elif not 0 < usage.get('calls', 0) <= 2 or usage.get('in', 0) <= 0 or usage.get('out', 0) <= 0:
        issues.append('invalid_or_empty_usage')
    elif usage['cached'] + (usage['writes'] if writes_known else 0) > usage['in']:
        issues.append('cached_and_written_tokens_exceed_input')
    elif len(api) != usage['calls']:
        issues.append('trace_call_count_does_not_match_usage')
    else:
        # Input is inclusive of reads and writes: never add cached tokens again.
        normalized = {'calls': usage['calls'], 'input_tokens': usage['in'],
                      'output_tokens': usage['out'], 'cached_input_tokens': usage['cached'],
                      'cache_write_tokens': usage['writes'],
                      'ordinary_input_tokens': usage['in'] - usage['cached'] - usage['writes'] if writes_known else None,
                      'cache_read_fraction': usage['cached'] / usage['in'],
                      'cost_usd': usage.get('cost_usd'), 'cost_kind': usage.get('cost_kind', 'unknown')}
        if usage.get('sub_calls') or usage.get('unpriced_calls'):
            normalized['cost_usd'] = None
    return {'valid': not issues, 'issues': issues, 'usage': normalized,
            'raw_final_usage': final_lines[-1] if final_lines else None,
            'unknown_usage_fields': [] if writes_known else ['cache_write_tokens', 'ordinary_input_tokens'],
            'parsed_final_usage': usage or None, 'observed_provider_models': identities,
            'observed_root_models': sorted({r.get('model', '') for r in roots}),
            'trace_api_calls': len(api)}


def run(binary, cwd, artifacts, model, prompt, timeout, source_env):
    artifacts.mkdir(mode=0o700)
    env = measurement.provider_environment('codegraff', str(artifacts), source_env, model)
    env['PWD'] = str(cwd)
    env['GRAFF_LEARNING_PRIVACY'] = 'local'
    with binary.open('rb') as executable:
        shebang = executable.readline(256)
    # Windows cannot launch Python scripts through CreateProcess by shebang.
    launcher = [sys.executable] if os.name == 'nt' and (binary.suffix.lower() == '.py' or
                (shebang.startswith(b'#!') and b'python' in shebang.lower())) else []
    argv = [*launcher, str(binary), '--no-local-tools', '--yolo', '--max-model-calls', '2',
            '--no-telemetry', '-p', prompt]
    expected_hash = digest(binary)
    started = time.monotonic_ns()
    proc = subprocess.Popen(argv, cwd=cwd, env=env, stdout=subprocess.PIPE,
                            stderr=subprocess.PIPE, text=True, start_new_session=True)
    timed_out = False
    try:
        stdout, stderr = proc.communicate(timeout=timeout)
    except subprocess.TimeoutExpired:
        timed_out = True
        if os.name == 'nt':
            proc.terminate()
        else:
            os.killpg(proc.pid, signal.SIGTERM)
        try:
            stdout, stderr = proc.communicate(timeout=5)
        except subprocess.TimeoutExpired:
            if os.name == 'nt':
                proc.kill()
            else:
                os.killpg(proc.pid, signal.SIGKILL)
            stdout, stderr = proc.communicate()
    wall_ns = time.monotonic_ns() - started
    measurement.private_logs(str(artifacts), stdout, stderr)
    rows, malformed = parse_trace(cwd)
    write_json(artifacts / 'trace-records.json', rows)
    result = validate(stdout, stderr, rows, model, proc.returncode, timed_out)
    if digest(binary) != expected_hash:
        result['valid'] = False
        result['issues'].append('binary_changed_during_run')
    if malformed:
        result['valid'] = False
        result['issues'].append('malformed_trace_records')
    result.update(wall_seconds=wall_ns / 1e9, binary_sha256=expected_hash,
                  prompt_sha256=hashlib.sha256(prompt.encode()).hexdigest(),
                  exit_code=proc.returncode, timed_out=timed_out,
                  requested_provider='codegraff', requested_model=model,
                  command_without_prompt=argv[:-1], artifacts=str(artifacts))
    write_json(artifacts / 'result.json', result)
    return result


def aggregate(pairs, models):
    output = {}
    for model in models:
        selected = [p for p in pairs if p['model'] == model]
        valid = [p for p in selected if all(p[arm][phase]['valid'] for arm in ('before', 'after')
                                          for phase in ('warm', 'linked'))]
        report = {'pairs': len(selected), 'valid_pairs': len(valid), 'metrics': {}}
        for metric in ('wall_seconds', 'input_tokens', 'output_tokens', 'cached_input_tokens',
                       'ordinary_input_tokens', 'cache_write_tokens', 'cache_read_fraction', 'cost_usd'):
            deltas, left, right = [], [], []
            for pair in valid:
                b, a = pair['before']['linked'], pair['after']['linked']
                bval = b[metric] if metric == 'wall_seconds' else b['usage'].get(metric)
                aval = a[metric] if metric == 'wall_seconds' else a['usage'].get(metric)
                if bval is not None and aval is not None:
                    left.append(bval)
                    right.append(aval)
                    deltas.append(aval - bval)
            report['metrics'][metric] = {'known_pairs': len(deltas),
                'before_median': statistics.median(left) if left else None,
                'after_median': statistics.median(right) if right else None,
                'paired_delta_median': statistics.median(deltas) if deltas else None}
        output[model] = report
    return output


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--before', required=True, type=Path)
    ap.add_argument('--after', required=True, type=Path)
    ap.add_argument('--model', required=True, action='append')
    ap.add_argument('--out', required=True, type=Path, help='New private artifact directory; must not exist')
    ap.add_argument('--repeats', type=int, default=3)
    ap.add_argument('--timeout', type=float, default=180)
    args = ap.parse_args()
    if args.repeats < 1 or args.timeout <= 0:
        ap.error('repeats and timeout must be positive')
    if len(set(args.model)) != len(args.model) or any(not m or '\n' in m or '\r' in m for m in args.model):
        ap.error('models must be unique nonempty single-line names')
    if not os.environ.get('CODEGRAFF_API_KEY'):
        ap.error('CODEGRAFF_API_KEY must be explicitly supplied')
    # Umask precedes all subprocesses, fixtures, HOME creation and trace output.
    os.umask(0o077)
    root = args.out.resolve()
    root.mkdir(mode=0o700, parents=False, exist_ok=False)
    binaries = root / 'binaries'
    binaries.mkdir(mode=0o700)
    copies, hashes = {}, {}
    for arm in ('before', 'after'):
        source = getattr(args, arm).resolve(strict=True)
        if not source.is_file() or not os.access(source, os.X_OK):
            ap.error(f'{arm} must be an executable file')
        before_hash = digest(source)
        dest = binaries / f'{arm}{source.suffix}'
        shutil.copyfile(source, dest)
        dest.chmod(0o500)
        if digest(dest) != before_hash or digest(source) != before_hash:
            raise RuntimeError('input binary changed while being captured')
        copies[arm], hashes[arm] = dest, before_hash
    if hashes['before'] == hashes['after']:
        ap.error('before/after binaries are identical; no treatment difference')
    write_json(root / 'manifest.json', {'binary_sha256': hashes, 'models': args.model,
               'repeats': args.repeats, 'source_equivalence': 'caller must establish cache-only difference',
               'design': 'separate real repositories per arm/repetition; primary warm then fresh linked',
               'caveat': 'fresh routing keys cannot force server cache coldness; automatic cache may ignore keys',
               'script_sha256': digest(Path(__file__).resolve()), 'measurement_sha256': digest(HELPERS)})
    env = {k: os.environ[k] for k in ('PATH', 'SYSTEMROOT') if k in os.environ}
    env.update(HOME=str(root), GIT_CONFIG_NOSYSTEM='1', GIT_CONFIG_GLOBAL=os.devnull)
    pairs = []
    for repeat in range(args.repeats):
        prompt = prompt_for(repeat)
        for model_index, model in enumerate(args.model):
            pair_root = root / f'pair-{repeat:02d}-{model_index:02d}'
            pair_root.mkdir(mode=0o700)
            (pair_root / 'prompt.txt').write_text(prompt)
            order = ('before', 'after') if (repeat + model_index) % 2 == 0 else ('after', 'before')
            pair = {'model': model, 'repeat': repeat, 'order': order}
            for arm in order:
                arm_root = pair_root / arm
                arm_root.mkdir(mode=0o700)
                primary, linked = fixture(arm_root, env)
                receipts = arm_root / 'receipts'
                receipts.mkdir(mode=0o700)
                pair[arm] = {}
                for phase, cwd in (('warm', primary), ('linked', linked)):
                    pair[arm][phase] = run(copies[arm], cwd, receipts / phase, model,
                                           prompt, args.timeout, os.environ)
                    print(json.dumps({'model': model, 'repeat': repeat, 'arm': arm, 'phase': phase,
                                      'valid': pair[arm][phase]['valid'], 'issues': pair[arm][phase]['issues']}), flush=True)
            pairs.append(pair)
            write_json(root / 'pairs.json', pairs)
            write_json(root / 'summary.json', aggregate(pairs, args.model))
    print(json.dumps({'summary': aggregate(pairs, args.model), 'artifacts': str(root)}, indent=2))
    if not all(p[arm][phase]['valid'] for p in pairs for arm in ('before', 'after') for phase in ('warm', 'linked')):
        raise SystemExit(1)


if __name__ == '__main__':
    main()
