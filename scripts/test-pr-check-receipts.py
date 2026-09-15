#!/usr/bin/env python3
"""Exercise actual completion dispatch with bounded local GitHub/model fixtures."""
import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
sys.path.insert(0, str(Path(__file__).resolve().parent / 'eval'))
from github_fixture import prepare
from mock_model import ScriptedModel
from process_guard import run


def tool(name, **arguments):
    return dict(tool=name, arguments=arguments)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--graff', default='zig-out/bin/graff')
    parser.add_argument('--evidence', type=Path, required=True)
    args = parser.parse_args()
    binary = str(Path(args.graff).resolve())
    checks = [dict(name='schema drift', status='COMPLETED', conclusion='SUCCESS'),
              dict(name='packed SDK', status='COMPLETED', conclusion='FAILURE'),
              dict(context='platform contract', state='PENDING')]
    cases = [
        ('failed', dict(check_rollup=checks), 'failed: CI reported a failure'),
        ('pending', dict(checks='PENDING'), 'pending: CI has not finished'),
        ('missing', dict(checks='NONE'), 'missing: no CI checks were reported'),
        ('unknown', dict(check_rollup=None), 'unknown: CI evidence is incomplete'),
        ('stale', dict(checks='SUCCESS', remote_head='a'*40), 'stale: local and remote heads differ'),
        ('unavailable', dict(pr_unavailable=True), 'checks could not be observed'),
        ('failed-exit-green-output', dict(checks='SUCCESS', pr_exit=7), 'checks could not be observed'),
        ('passed', dict(checks='SUCCESS'), None),
    ]
    for name, state, expected in cases:
        with tempfile.TemporaryDirectory(prefix='graff-check-receipt-') as temp:
            work = Path(temp)
            env = {k: v for k, v in os.environ.items() if not k.endswith('_API_KEY')}
            env.update(HOME=temp, LMSTUDIO_API_KEY='local', GRAFF_FLEET='off',
                       GRAFF_NO_TELEMETRY='1', GRAFF_NO_SMOLIFY='1', GRAFF_NO_CODEDB_GUARD='1')
            prepare(work, env, dict(checks='SUCCESS'))
            # Publish while evidence is green, then change the current observation.
            (work/'next-state.json').write_text(json.dumps(state))
            (work/'change.py').write_text("import json,pathlib\np=pathlib.Path('gh-state.json')\ns=json.loads(p.read_text());s.update(json.loads(pathlib.Path('next-state.json').read_text()));p.write_text(json.dumps(s))\n")
            attempt = tool('attempt_completion', result='Verification complete.')
            model = ScriptedModel([
                tool('bash', command='gh pr create --title fixture --body-file notes.md'),
                tool('bash', command=f'{sys.executable} change.py'),
                tool('todo_write', todos=[dict(content='verify CI', status='completed')]),
                attempt, attempt, dict(text='Verification remains unresolved.'),
            ])
            model.start(1234)
            try:
                result = run([binary, '--json', '--old', '--yolo', '--model', 'lmstudio'],
                             cwd=work, env=env, text=True, capture_output=True, timeout=90,
                             input=json.dumps(dict(type='user', text='Run the publication verification fixture.'))+'\n')
                assert result.returncode == 0, result.stderr[-3000:]
                events = [json.loads(line) for line in result.stdout.splitlines() if line.startswith('{')]
                completions = [e for e in events if e.get('type') == 'tool_call_finished' and e.get('name') == 'attempt_completion']
                assert completions, events
                requests = json.dumps(model.requests)
                if expected:
                    assert expected in requests, requests[-5000:]
                    assert all(e.get('is_error') for e in completions), completions
                    assert len(completions) >= 2, completions
                else:
                    assert any(not e.get('is_error') for e in completions), completions
                files = list((work/'.graff/pr-verification').glob('*.receipt.json'))
                assert len(files) == 1, files
                receipt = json.loads(files[0].read_text())
                if state.get('pr_unavailable') or state.get('pr_exit'):
                    assert receipt['observation'] == 'unavailable' and receipt['receipt'] is None, receipt
                else:
                    assert receipt['receipt']['head'] == state.get('remote_head', receipt['local_head']), receipt
                    if name == 'failed':
                        assert json.loads(receipt['receipt']['checks_json']) == checks, receipt
                        for check in ('schema drift', 'packed SDK', 'platform contract'):
                            assert check in requests, check
                output = args.evidence/name
                output.mkdir(parents=True, exist_ok=True)
                (output/'events.json').write_text(json.dumps(events, indent=2))
                (output/'requests.json').write_text(json.dumps(model.requests, indent=2))
                (output/'receipt.json').write_text(json.dumps(receipt, indent=2))
                (output/'stderr.log').write_text(result.stderr)
                if (work/'.graff/traces').exists():
                    shutil.copytree(work/'.graff/traces', output/'traces', dirs_exist_ok=True)
                print(f'PASS {name}: actual completion results and persisted receipt agree', flush=True)
            finally:
                model.stop()


if __name__ == '__main__':
    main()
