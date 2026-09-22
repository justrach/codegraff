#!/usr/bin/env python3
"""Offline real-harness check: an endless tool model hits the shared ceiling."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

sys.path.insert(0, str(Path(__file__).resolve().parent / 'eval'))
from mock_model import ScriptedModel


class EndlessModel(ScriptedModel):
    def __init__(self):
        super().__init__([])

    def next_reply(self, body):
        with self._lock:
            self.requests.append(body)
        return {'tool': 'clock_sleep', 'arguments': {'ms': 0}}


def check(binary):
    model = EndlessModel()
    port = model.start(0)
    try:
        with tempfile.TemporaryDirectory(prefix='graff-tool-budget-') as temp:
            env = {k: v for k, v in os.environ.items()
                   if not k.endswith('_API_KEY') and not k.startswith(('GRAFF_', 'HARNESS_'))}
            env.update(HOME=temp, AI_GATEWAY_API_KEY='local', GRAFF_FLEET='off',
                       GRAFF_VERCEL_URL=f'http://127.0.0.1:{port}/v1/chat/completions',
                       GRAFF_NO_TELEMETRY='1', GRAFF_NO_SMOLIFY='1', NO_COLOR='1')
            done = subprocess.run([str(binary), '--json', '--yolo', '--old', '--no-lean',
                                   '--clock-sleep', '--max-run-tool-calls', '2', '--model', 'vercel'],
                                  cwd=temp, env=env, input=json.dumps({'type': 'user',
                                  'text': 'Repeat clock_sleep with zero milliseconds.'}) + '\n',
                                  text=True, capture_output=True, timeout=25)
            events = [json.loads(line) for line in done.stdout.splitlines() if line.startswith('{')]
            results = [e for e in events if e.get('type') == 'tool_call_finished']
            rejected = [e for e in events if e.get('type') == 'tool_rejected' and e.get('reason') == 'exhausted']
            assert len(rejected) == 1, (done.stdout[-2500:], done.stderr[-1000:])
            assert json.loads(rejected[0]['message']) == {
                'event': 'exhausted', 'dimension': 'tool_calls', 'used': 2, 'limit': 2}
            assert len(model.requests) == 3, len(model.requests)
            assert len(results) == 3, results
            assert sum(not e.get('is_error') for e in results) == 2, results
            assert 'ToolBudgetExhausted' in done.stdout + done.stderr, (done.stdout, done.stderr)
            print('PASS aggregate tool budget: endless model stops after two admitted calls and exact exhaustion')
    finally:
        model.stop()


if __name__ == '__main__':
    check(Path(sys.argv[1] if len(sys.argv) > 1 else 'zig-out/bin/graff').resolve())
