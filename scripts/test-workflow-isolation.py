#!/usr/bin/env python3
"""Offline real-worker test: dependent stages share a tree; items stay apart."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

sys.path.insert(0, str(Path(__file__).parent / 'eval'))
from mock_model import ScriptedModel


class Model(ScriptedModel):
    def __init__(self, phases=False):
        super().__init__([])
        self.phases = phases
        self.observed = []

    def next_reply(self, body):
        with self._lock:
            self.requests.append(body)
        messages = body.get('messages', [])
        users = '\n'.join(str(m.get('content', '')) for m in messages if m.get('role') == 'user')
        results = [m for m in messages if m.get('role') == 'tool']
        if 'WRITE_FIXTURE' in users and 'ROOT_FIXTURE' not in users:
            if not results:
                item = 'beta' if 'Item: beta' in users else 'alpha'
                return {'tool': 'bash', 'arguments': {'command':
                    f'printf {item} > result.txt && git add result.txt && '
                    'git -c user.name=Fixture -c user.email=fixture@example.invalid commit -qm fixture'}}
            return {'text': 'write stage complete'}
        if 'READ_FIXTURE' in users and 'ROOT_FIXTURE' not in users:
            if not results:
                return {'tool': 'bash', 'arguments': {'command': 'cat result.txt'}}
            content = str(results[-1].get('content', ''))
            with self._lock:
                self.observed.append(content)
            return {'text': 'read stage verified'}
        if results:
            return {'text': 'WORKFLOW_COMPLETE'}
        write = {'description': 'transform', 'prompt': 'WRITE_FIXTURE: create and commit the fixture.'}
        read = {'description': 'verify', 'prompt': 'READ_FIXTURE: read the previously written fixture.'}
        args = ({'isolation': 'worktree', 'phases': [
            {'title': 'implement', 'tasks': [write]}, {'title': 'verify', 'tasks': [read]}]}
            if self.phases else {'pipeline': {'isolation': 'worktree', 'items': ['alpha', 'beta'], 'stages': [write, read]}})
        return {'tool': 'workflow', 'arguments': args}


def check(binary, phases):
    model = Model(phases)
    port = model.start(0)
    try:
        with tempfile.TemporaryDirectory(prefix='graff-workflow-isolation-') as temp:
            root = Path(temp)
            env = {k: v for k, v in os.environ.items() if not k.endswith('_API_KEY') and not k.startswith(('GRAFF_', 'HARNESS_'))}
            env.update(HOME=temp, AI_GATEWAY_API_KEY='local', GRAFF_VERCEL_URL=f'http://127.0.0.1:{port}/v1/chat/completions', GRAFF_FLEET='off',
                       GRAFF_NO_TELEMETRY='1', GRAFF_NO_SMOLIFY='1', NO_COLOR='1')
            for args in [['git', 'init', '-q'], ['git', '-c', 'user.name=Fixture', '-c',
                         'user.email=fixture@example.invalid', 'commit', '--allow-empty', '-qm', 'initial']]:
                subprocess.run(args, cwd=root, env=env, check=True, capture_output=True)
            done = subprocess.run([str(binary), '--json', '--yolo', '--old', '--no-lean', '--model', 'vercel'],
                                  cwd=root, env=env, input=json.dumps({'type': 'user', 'text':
                                  'ROOT_FIXTURE: run the implementation and independent verification workflow. Use the workflow tool with subagents exactly as supplied.'})+'\n',
                                  text=True, capture_output=True, timeout=90)
            assert done.returncode == 0, done.stderr[-2000:]
            events = [json.loads(line) for line in done.stdout.splitlines() if line.startswith('{')]
            tool_results = [e for e in events if e.get('type') == 'tool_result']
            text = json.dumps(tool_results)
            assert 'workflow changes retained' in text, text[-3000:]
            expected = ['alpha'] if phases else ['alpha', 'beta']
            assert len(model.observed) == len(expected), model.observed
            assert all(any(item in content for content in model.observed) for item in expected), model.observed
            assert not (root/'result.txt').exists(), 'isolated writes reached caller checkout'
            trees = list((root/'.graff/worktrees').glob('agent-workflow-*'))
            assert len(trees) == len(expected), trees
            assert sorted((tree/'result.txt').read_text() for tree in trees) == expected
            def values(item):
                if isinstance(item, str):
                    yield item
                elif isinstance(item, dict):
                    for value in item.values():
                        yield from values(value)
                elif isinstance(item, list):
                    for value in item:
                        yield from values(value)

            def path_text(value):
                return value.replace(chr(92) * 2, chr(92)).replace(chr(92), '/').casefold()

            delivered = path_text('\n'.join(values(tool_results)))
            for tree in trees:
                expected_path = path_text(str(tree))
                assert expected_path in delivered, 'retained path was not delivered'
                branch = subprocess.check_output(['git', '-C', str(tree), 'branch', '--show-current'], text=True).strip()
                assert branch in text, 'retained branch was not delivered'
            print(f'PASS {"phases" if phases else "pipeline"}: dependent reads, isolated items, committed trees retained and delivered')
    finally:
        model.stop()


if __name__ == '__main__':
    binary = Path(sys.argv[1] if len(sys.argv) > 1 else 'zig-out/bin/graff').resolve()
    check(binary, False)
    check(binary, True)
