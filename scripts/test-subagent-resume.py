#!/usr/bin/env python3
"""Offline real parent/child continuation with retained evidence and queued mail."""
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile

sys.path.insert(0, str(Path(__file__).resolve().parent / 'eval'))
from mock_model import ScriptedModel


class ResumeModel(ScriptedModel):
    def __init__(self):
        super().__init__([])
        self.parent_calls = 0
        self.child_calls = 0
        self.checked = False

    def next_reply(self, body):
        super().next_reply(body)
        messages = body.get('messages', [])
        first = next((m for m in messages if m.get('role') == 'user'), {})
        if 'CHILD_RETAINED_FIXTURE' in json.dumps(first):
            self.child_calls += 1
            if self.child_calls == 1:
                return {'text': 'ORIGINAL_EVIDENCE'}
            text = json.dumps(messages)
            self.checked = self.child_calls == 2 and all(x in text for x in
                ('ORIGINAL_EVIDENCE', 'QUEUED_EVIDENCE', 'FOLLOWUP_REQUEST'))
            return {'text': 'RESUMED_EVIDENCE' if self.checked else 'MISSING_HISTORY'}
        step = self.parent_calls
        self.parent_calls += 1
        outputs = json.dumps([m for m in messages if m.get('role') == 'tool'])
        if step == 0:
            return {'tool': 'subagent', 'arguments': {'description': 'Retained fixture',
                'prompt': 'CHILD_RETAINED_FIXTURE: return original evidence.', 'isolation': 'shared_cwd', 'retained': True}}
        match = re.search(r'task_id ([a-f0-9]{32})', outputs)
        if not match:
            return {'text': 'NO_WORKER_ID'}
        task_id = match[1]
        if step == 1:
            return {'tool': 'agent_message', 'arguments': {'task_id': task_id, 'message': 'QUEUED_EVIDENCE'}}
        if step == 2:
            assert self.child_calls == 1, 'queue-only message unexpectedly ran a turn'
            return {'tool': 'subagent_resume', 'arguments': {'task_id': task_id, 'message': 'FOLLOWUP_REQUEST'}}
        if step == 3:
            match = re.search(r'agent (\d+) started', outputs)
            return {'tool': 'agent_output', 'arguments': {'id': int(match[1]) if match else 1, 'wait_ms': 10000}}
        return {'text': 'RESUME_TEST_DONE' if self.checked and 'RESUMED_EVIDENCE' in outputs else 'RESUME_TEST_FAILED'}


class EphemeralModel(ScriptedModel):
    def __init__(self, background, explicit):
        super().__init__([])
        self.background, self.explicit = background, explicit
        self.parent_calls = 0

    def next_reply(self, body):
        super().next_reply(body)
        messages = body.get('messages', [])
        first = next((m for m in messages if m.get('role') == 'user'), {})
        if 'EPHEMERAL_CHILD' in json.dumps(first):
            return {'text': 'EPHEMERAL_DONE'}
        step = self.parent_calls
        self.parent_calls += 1
        if step == 0:
            args = {'prompt': 'EPHEMERAL_CHILD: reply once.', 'isolation': 'shared_cwd',
                    'run_in_background': self.background}
            if self.explicit:
                args['retained'] = False
            return {'tool': 'subagent', 'arguments': args}
        outputs = json.dumps([m for m in messages if m.get('role') == 'tool'])
        assert 'task_id' not in outputs, outputs
        if self.background and step == 1:
            handle = re.search(r'agent (\d+) started', outputs)
            assert handle, outputs
            return {'tool': 'agent_output', 'arguments': {'id': int(handle[1]), 'wait_ms': 10000}}
        assert 'EPHEMERAL_DONE' in outputs, outputs
        return {'text': 'EPHEMERAL_TEST_DONE'}


def check(binary, background=None, explicit=False):
    model = ResumeModel() if background is None else EphemeralModel(background, explicit)
    port = model.start(0)
    try:
        with tempfile.TemporaryDirectory(prefix='graff-worker-resume-') as temp:
            env = {k: v for k, v in os.environ.items()
                   if not k.endswith('_API_KEY') and not k.startswith(('GRAFF_', 'HARNESS_'))}
            env.update(HOME=temp, AI_GATEWAY_API_KEY='local', GRAFF_FLEET='off',
                       GRAFF_VERCEL_URL=f'http://127.0.0.1:{port}/v1/chat/completions',
                       GRAFF_NO_TELEMETRY='1', GRAFF_NO_SMOLIFY='1', NO_COLOR='1')
            done = subprocess.run([str(binary), '--json', '--yolo', '--old', '--no-lean', '--model', 'vercel'],
                cwd=temp, env=env, input=json.dumps({'type': 'user', 'text': 'Run the retained worker fixture.'})+'\n',
                text=True, capture_output=True, timeout=35)
            marker = 'RESUME_TEST_DONE' if background is None else 'EPHEMERAL_TEST_DONE'
            assert done.returncode == 0 and marker in done.stdout, (done.stdout[-10000:], done.stderr[-2000:])
            records = list(Path(temp).glob('.graff/sessions/*/workers/*.json'))
            if background is not None:
                assert not records, records
                print(f'PASS ephemeral worker: background={background}, explicit_false={explicit}, no history or task_id')
                return
            assert model.checked and model.child_calls == 2, (model.checked, model.child_calls)
            assert len(records) == 1, records
            record = json.loads(records[0].read_text())
            assert 'RESUMED_EVIDENCE' in json.dumps(record['messages']) and not record['pending']
            print('PASS retained worker: original history, queue without execution, same-worker continuation and durable checkpoint')
    finally:
        model.stop()


if __name__ == '__main__':
    binary = Path(sys.argv[1] if len(sys.argv)>1 else 'zig-out/bin/graff').resolve()
    check(binary)
    for background in (False, True):
        for explicit in (False, True):
            check(binary, background, explicit)
