#!/usr/bin/env python3
"""Offline #1166 stress: fast shell batches, exact results, next turn, clean exit.

Uses the same real harness and scripted HTTP model as tier 2. On macOS enable
malloc scribbling and heap checks; Zig-owned allocations retain build checks.
Run: python3 scripts/eval/parallel_shell_stress.py --repeat 20
"""
import argparse
from collections import Counter
import importlib.util
import json
from pathlib import Path
import platform
import shlex
import sys

REPO = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('tier2', REPO / 'scripts/eval-tier2.py')
tier2 = importlib.util.module_from_spec(spec)
spec.loader.exec_module(tier2)


def make_case(iteration, count, legacy=False, barrier=False):
    sizes = [0, 1, 31, 255, 1023, 2047, 4095, 8191]
    expected = {}
    calls = []
    for i in range(count):
        size = sizes[(i + iteration) % len(sizes)]
        marker = f'RESULT-{iteration}-{i}:'
        expected[f'call_1_{i}'] = marker + chr(65 + i % 26) * size + ':END'
        # A separate overlap run waits for every process to start; fast runs
        # have no sleeps/barriers, stressing simultaneous job completion.
        setup = ''
        if barrier:
            setup = (f'from pathlib import Path; import time; '
                     f'Path("started-{i}").touch(); deadline=time.monotonic()+5; '
                     f'\nwhile len(list(Path(".").glob("started-*"))) < {count}:\n'
                     ' assert time.monotonic()<deadline, "batch serialized"\n time.sleep(.005)\n')
        code = setup + f'print({marker!r} + {chr(65 + i % 26)!r} * {size} + ":END")'
        calls.append({'tool': 'bash' if legacy else 'shell',
                      'arguments': {'command': ('printf %s ' + shlex.quote(expected[f'call_1_{i}'])
                                                if not barrier and size < 256
                                                else 'python3 -c ' + shlex.quote(code))}})
    case = {
        'id': f'parallel-shell-{iteration}-{count}-' + ('bash' if legacy else 'shell') + ('-overlap' if barrier else ''),
        'prompt': 'Execute the independent fixture commands, then report completion.',
        'args': ['--old'] if legacy else [],
        'script': [{'tools': calls}, {'text': 'BATCH-COMPLETE'}],
        'timeout_s': 45,
        'assert': [{'final_text_contains': 'BATCH-COMPLETE'}],
        'env': {},
    }
    if platform.system() == 'Darwin':
        case['env'] = {'MallocScribble': '1', 'MallocPreScribble': '1',
                       'MallocCheckHeapStart': '1', 'MallocCheckHeapEach': '1000',
                       'MallocErrorAbort': '1', 'MallocNanoZone': '0'}
    return case, expected


def verify(case, expected, run):
    failures = tier2.evaluate(case, run)
    if run.exit_code != 0:
        failures.append(f'process exit {run.exit_code}')
    if len(run.requests) != 2:
        failures.append(f'expected two model requests, got {len(run.requests)}')
    results = [e for e in run.events if e.get('type') == 'tool_result']
    ids = Counter(e.get('id') for e in results)
    if ids != Counter({key: 1 for key in expected}):
        failures.append(f'tool-result identity/count mismatch: {ids}')
    for event in results:
        wanted = expected.get(event.get('id'))
        if wanted is not None and wanted not in event.get('text', ''):
            failures.append(f'wrong result bytes for {event.get("id")}')
        if event.get('is_error') or event.get('cancelled'):
            failures.append(f'failed/cancelled result {event.get("id")}')
    if len(run.requests) >= 2:
        messages = [m for m in run.requests[1].get('messages', []) if m.get('role') == 'tool']
        if Counter(m.get('tool_call_id') for m in messages) != Counter({key: 1 for key in expected}):
            failures.append('second request missing/duplicating tool results')
        for message in messages:
            wanted = expected.get(message.get('tool_call_id'))
            if wanted is not None and wanted not in message.get('content', ''):
                failures.append(f'corrupt model result {message.get("tool_call_id")}')
    for marker in ('memory corruption', 'double free', 'use after free', 'incorrect checksum', 'panic:'):
        if marker in run.stderr.lower():
            failures.append(f'allocator/runtime diagnostic: {marker}')
    return failures


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--graff', default=str(REPO / 'zig-out/bin/graff'))
    parser.add_argument('--repeat', type=int, default=20)
    parser.add_argument('--evidence-dir', type=Path)
    args = parser.parse_args()
    if args.repeat < 1:
        parser.error('--repeat must be positive')
    scenarios = [(n, [2, 3, 5, 8][n % 4], n % 2 == 1, False) for n in range(args.repeat)]
    scenarios += [(args.repeat, 3, False, True)]
    total = 0
    for scenario in scenarios:
        case, expected = make_case(*scenario)
        run = tier2.execute(case, str(Path(args.graff).resolve()), 1234, None, None, args.evidence_dir)
        failures = verify(case, expected, run)
        if failures:
            print(json.dumps({'case': case['id'], 'failures': failures, 'stderr': run.stderr[-2000:]}, indent=2))
            return 1
        total += len(expected)
        print(f'PASS {case["id"]}: {len(expected)} exact results; resumed; exit 0', flush=True)
    print(f'PASS {len(scenarios)} processes / {total} shell results; allocator diagnostics={platform.system() == "Darwin"}')
    return 0


if __name__ == '__main__':
    sys.exit(main())
