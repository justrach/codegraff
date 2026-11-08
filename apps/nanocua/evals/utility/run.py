#!/usr/bin/env python3
"""Same Codegraff agent, five synthetic tasks, five observation policies.

Only generated fixture content is sent to the configured model. Every run has
an isolated HOME/cwd/MCP config. No desktop server or local file/shell tools.
Results distinguish task failures from agent startup/infrastructure failures.
"""
import argparse
from concurrent.futures import ThreadPoolExecutor, as_completed
import json
import os
from pathlib import Path
import re
import signal
import subprocess
import sys
import tempfile
import time

from fixture import CASES, MODES

HERE = Path(__file__).resolve().parent
APP = HERE.parent.parent
SYSTEM = '''You are testing a synthetic application through nanocua MCP tools.
Only use nanocua tools and load_tool_schemas if needed. Never use other tools,
network, files, shell, subagents, screenshots, or real applications.
Start with get_ui_tree using its default options. Act using refs returned by
the latest tree, not guessed refs or coordinates. If a necessary label or
result is absent, request get_ui_tree with interactive_only:false and
include_frames:false. If that still omits it, report that you cannot read it.
After acting, read the tree again to verify the actual result. Do not calculate,
infer, or guess an answer that the tool did not show. Return the requested
answer concisely. Do not explain the test or request permissions.'''


def correct_answer(case, answer):
    s = re.sub(r'\s+', ' ', answer.lower()).replace(',', '')
    if case == 'file_info':
        return all(re.search(r'\b' + n + r'\b', s.replace('x', ' ')) for n in ('26', '1080', '1920', '2496326'))
    if case == 'toggle':
        return re.search(r'\b(on|enabled)\b', s) is not None
    if case == 'calculator':
        return re.search(r'\b42\b', s) is not None
    return CASES[case]['answer'].lower() in s


def run_one(args, case, mode):
    started = time.monotonic()
    with tempfile.TemporaryDirectory(prefix='nanocua-utility-') as tmp:
        home = Path(tmp)
        state = home / 'state.json'
        config = home / 'mcp.json'
        config.write_text(json.dumps({'mcpServers': {'nanocua': {
            'command': sys.executable,
            'args': [str(HERE / 'fixture.py'), '--renderer', str(args.renderer),
                     '--case', case, '--mode', mode, '--state', str(state)],
        }}}))
        env = dict(os.environ, HOME=tmp, USERPROFILE=tmp,
                   GRAFF_MCP_CONFIG=str(config), GRAFF_NO_PLUGINS='1',
                   GRAFF_NO_TELEMETRY='1', GRAFF_FLEET='off', GRAFF_NO_SMOLIFY='1')
        command = [str(args.graff), '-p', '--yolo', '--no-local-tools', '--no-rlm',
                   '--no-lean', '--no-telemetry', '--learning-privacy', 'local',
                   '--max-model-calls', '12', '--max-run-tool-calls', '32',
                   '--output-format', 'stream-json', '--system-prompt', SYSTEM]
        if args.model:
            command.extend(['--model', args.model])
        command.append(CASES[case]['prompt'])
        proc = subprocess.Popen(command, cwd=tmp, env=env, text=True,
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                start_new_session=True)
        timed_out = False
        try:
            stdout, stderr = proc.communicate(timeout=args.timeout)
        except subprocess.TimeoutExpired:
            timed_out = True
            os.killpg(proc.pid, signal.SIGTERM)
            try:
                stdout, stderr = proc.communicate(timeout=5)
            except subprocess.TimeoutExpired:
                os.killpg(proc.pid, signal.SIGKILL)
                stdout, stderr = proc.communicate()
        events = []
        for line in stdout.splitlines():
            try:
                events.append(json.loads(line))
            except ValueError:
                pass
        final = next((e for e in reversed(events) if e.get('type') == 'result'), {})
        answer = final.get('result', '')
        evidence = json.loads(state.read_text()) if state.exists() else {}
        attempted = evidence.get('tool_calls', 0) > 0
        verified = (evidence.get('action_succeeded', False)
                    and evidence.get('success_observed', False) and correct_answer(case, answer))
        passed = proc.returncode == 0 and verified
        row = dict(case=case, mode=mode, passed=bool(passed), verified_answer=bool(verified),
                   status='pass' if passed else ('task_failure' if attempted else 'infrastructure_failure'),
                   exit_code=proc.returncode, timed_out=timed_out,
                   seconds=round(time.monotonic() - started, 2), answer=answer,
                   usage=final.get('usage'), **evidence)
        # Never save raw harness logs, paths, credentials, or session metadata.
        if not attempted:
            row['diagnostic'] = ('timeout before a fixture call' if timed_out else
                                 'agent exited before a fixture call; check credentials/network')
            print(f'{case}/{mode}: {row["diagnostic"]} (exit {proc.returncode})', file=sys.stderr)
            # The last line is displayed locally for a failed pilot, not persisted.
            if args.diagnostics and stderr.strip():
                print(stderr.splitlines()[-1][:500], file=sys.stderr)
        return row


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--graff', type=Path, required=True)
    p.add_argument('--renderer', type=Path, default=APP / 'zig-out/bin/nanocua-utility-render')
    p.add_argument('--model', help='Use the same explicit model for every run; otherwise the isolated agent default')
    p.add_argument('--cases', nargs='+', choices=CASES, default=list(CASES))
    p.add_argument('--modes', nargs='+', choices=MODES, default=list(MODES))
    p.add_argument('--jobs', type=int, default=2)
    p.add_argument('--timeout', type=int, default=120)
    p.add_argument('--output', type=Path, required=True)
    p.add_argument('--resume', action='store_true', help='Keep already measured case/mode pairs')
    p.add_argument('--retry-infrastructure', action='store_true',
                   help='With --resume, retry only infrastructure failures; retain failed attempts')
    p.add_argument('--diagnostics', action='store_true')
    args = p.parse_args()
    args.graff, args.renderer = args.graff.resolve(), args.renderer.resolve()
    previous = json.loads(args.output.read_text()) if args.resume and args.output.exists() else {}
    rows = previous.get('runs', [])
    attempts = previous.get('infrastructure_attempts', [])
    if args.retry_infrastructure:
        retry = [r for r in rows if r['status'] == 'infrastructure_failure'
                 and r['case'] in args.cases and r['mode'] in args.modes]
        attempts.extend(retry)
        rows = [r for r in rows if r not in retry]
    for row in rows:
        row.setdefault('verified_answer', bool(row.get('action_succeeded') and
                       row.get('success_observed') and correct_answer(row['case'], row.get('answer', ''))))
    done = {(r['case'], r['mode']) for r in rows}
    jobs = [(c, m) for c in args.cases for m in args.modes if (c, m) not in done]
    args.output.parent.mkdir(parents=True, exist_ok=True)
    with ThreadPoolExecutor(max_workers=args.jobs) as pool:
        pending = {pool.submit(run_one, args, c, m): (c, m) for c, m in jobs}
        for future in as_completed(pending):
            row = future.result()
            rows.append(row)
            args.output.write_text(json.dumps(dict(
                scope='synthetic stateful MCP fixtures; production tree serializer; not native desktop automation',
                infrastructure_attempts=attempts,
                runs=sorted(rows, key=lambda r: (r['case'], r['mode']))), indent=2) + '\n')
            print(f'{row["case"]}/{row["mode"]}: {row["status"]}; '
                  f'{row.get("tool_calls", 0)} calls; {row.get("observation_bytes", 0)} observation bytes', flush=True)
    for mode in args.modes:
        group = [r for r in rows if r['mode'] == mode and r['case'] in args.cases]
        print(f'{mode}: {sum(r["passed"] for r in group)}/{len(group)} pass; '
              f'{sum(r.get("observation_bytes", 0) for r in group)} observation bytes')
    return int(any(r['status'] == 'infrastructure_failure' for r in rows))


if __name__ == '__main__':
    sys.exit(main())
