#!/usr/bin/env python3
"""Offline fork-history integration on ACP and legacy JSON; no live model calls."""
import importlib.util
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import threading
import time
import traceback

REPO = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPO / 'scripts/eval'))
from mock_model import ScriptedModel

spec = importlib.util.spec_from_file_location('acp_load', REPO / 'scripts/test-acp-session-load.py')
acp_load = importlib.util.module_from_spec(spec)
spec.loader.exec_module(acp_load)
Acp = acp_load.Acp

# A developer's proxy must never receive this fixture's loopback requests.
LOCAL_NETWORK_ENV = {key: '' for key in (
    'http_proxy', 'https_proxy', 'all_proxy', 'HTTP_PROXY', 'HTTPS_PROXY', 'ALL_PROXY')}
LOCAL_NETWORK_ENV.update(no_proxy='*', NO_PROXY='*')


def text(messages):
    return json.dumps(messages)


def tool(name, **arguments):
    return {'tool': name, 'arguments': arguments}


def task(name, suffix=''):
    return {'description': 'Fork fixture ' + name,
            'prompt': 'FORK_TASK:' + name + ' Reply once. ' + suffix,
            'isolation': 'shared_cwd'}


def spawn(name, source=None, retained=False, background=False):
    args = task(name)
    args.update(retained=retained, run_in_background=background)
    if source is not None:
        args['fork_from'] = source
    return tool('subagent', **args)


def outputs(body):
    return text([m for m in body['messages'] if m.get('role') == 'tool'])


def last_output(body):
    return text(next(m for m in reversed(body['messages']) if m.get('role') == 'tool'))


def worker_id(body):
    match = re.search(r'task_id ([a-f0-9]{32})', last_output(body))
    assert match, 'missing retained task_id: ' + last_output(body)
    return match[1]


def wait_reply(body):
    match = re.search(r'agent (\d+) started', last_output(body))
    assert match, 'missing background handle: ' + last_output(body)
    return tool('agent_output', id=int(match[1]), wait_ms=10000)


def wait_file(path, needle):
    deadline = time.monotonic() + 5
    while time.monotonic() < deadline:
        try:
            data = path.read_bytes()
        except FileNotFoundError:
            data = b''
        if needle.encode() in data:
            return data
        time.sleep(.05)
    raise AssertionError('checkpoint never persisted ' + needle)


def checkpoint(root, ident, answer):
    paths = list(root.glob('.graff/sessions/*/workers/' + ident + '.json'))
    assert len(paths) == 1, (ident, paths)
    data = wait_file(paths[0], answer)
    record = json.loads(data)
    assert record['id'] == ident and not record['pending'], record
    assert answer in text(record['messages'])
    return paths[0], data


def unchanged(snapshot):
    path, data = snapshot
    assert path.read_bytes() == data, 'fork rewrote source checkpoint: ' + path.name


def contains(body, *needles):
    sent = text(body['messages'])
    for needle in needles:
        assert needle in sent, 'request lost ' + needle


def excludes(body, *needles):
    sent = text(body['messages'])
    for needle in needles:
        assert needle not in sent, 'request leaked ' + needle


def native_evidence(body):
    messages = body['messages']
    calls = [c for m in messages for c in m.get('tool_calls', [])]
    evidence = [c for c in calls if c['function']['name'] == 'bash'
                and 'CURRENT_EVIDENCE' in c['function']['arguments']]
    assert len(evidence) == 1, 'completed native call was not preserved'
    assert any(m.get('role') == 'tool' and m.get('tool_call_id') == evidence[0]['id']
               and 'CURRENT_EVIDENCE' in text(m.get('content')) for m in messages)
    assert not any(c['function']['name'] == 'subagent' for c in calls), 'unfinished spawn copied'


class ForkModel(ScriptedModel):
    def __init__(self, root, saved, workflows):
        super().__init__([])
        self.root, self.saved, self.workflows = root, saved, workflows
        self.route_lock = threading.Lock()
        self.seen = {}
        self.errors = []
        self.finished = False
        self.original_id = None
        self.parent = self.sequence()
        self.started = False

    def next_reply(self, body):
        super().next_reply(body)
        # Do not classify against the first user: forked children inherit it.
        latest = next((m for m in reversed(body.get('messages', []))
                       if m.get('role') == 'user'), {})
        markers = re.findall(r'FORK_TASK:([A-Z0-9_]+)', text(latest.get('content', '')))
        with self.route_lock:
            try:
                assert markers, 'request has no task marker'
                # Lightweight workers prepend the parent's request as context.
                name = markers[-1]
                if name != 'ROOT':
                    self.seen.setdefault(name, []).append(body)
                    return {'text': 'ANSWER_' + name}
                if not self.started:
                    self.started = True
                    return next(self.parent)
                return self.parent.send(body)
            except Exception:
                self.errors.append(traceback.format_exc())
                return {'text': 'FORK_FIXTURE_FAILED'}

    def request_for(self, name):
        requests = self.seen.get(name, [])
        assert len(requests) == 1, (name, len(requests))
        return requests[0]

    def sequence(self):
        body = yield tool('bash', command='printf CURRENT_EVIDENCE')
        assert 'CURRENT_EVIDENCE' in last_output(body)
        body = yield spawn('CURRENT', 'current')
        contains(self.request_for('CURRENT'), 'FORK_TASK:ROOT', 'CURRENT_EVIDENCE')
        native_evidence(self.request_for('CURRENT'))
        assert 'ANSWER_CURRENT' in last_output(body)
        # Background execution must still return an owned handle and durable id.
        body = yield spawn('BACKGROUND', 'current', retained=True, background=True)
        background_id = worker_id(body)
        body = yield wait_reply(body)
        assert 'ANSWER_BACKGROUND' in last_output(body)
        background = checkpoint(self.root, background_id, 'ANSWER_BACKGROUND')
        contains(self.request_for('BACKGROUND'), 'CURRENT_EVIDENCE')

        body = yield spawn('SAVED', 'session:' + self.saved[0])
        contains(self.request_for('SAVED'), 'FORK_TASK:SOURCE', 'ANSWER_SOURCE')
        excludes(self.request_for('SAVED'), 'CURRENT_EVIDENCE', 'ANSWER_CURRENT')
        unchanged(self.saved[1])
        assert 'ANSWER_SAVED' in last_output(body)

        body = yield spawn('ORIGINAL', retained=True)
        self.original_id = worker_id(body)
        contains(self.request_for('ORIGINAL'), 'FORK_TASK:ROOT')
        excludes(self.request_for('ORIGINAL'), 'CURRENT_EVIDENCE', 'ANSWER_CURRENT',
                 'ANSWER_BACKGROUND', 'ANSWER_SOURCE', 'ANSWER_SAVED')
        original = checkpoint(self.root, self.original_id, 'ANSWER_ORIGINAL')
        source = 'worker:' + self.original_id
        branches = []
        ids = {background_id, self.original_id}
        for name, other in [('BRANCH_A', 'BRANCH_B'), ('BRANCH_B', 'BRANCH_A')]:
            body = yield spawn(name, source, retained=True)
            ident = worker_id(body)
            assert ident not in ids, 'fork reused worker id'
            ids.add(ident)
            branches.append(checkpoint(self.root, ident, 'ANSWER_' + name))
            contains(self.request_for(name), 'FORK_TASK:ORIGINAL', 'ANSWER_ORIGINAL')
            excludes(self.request_for(name), 'ANSWER_' + other)
            unchanged(original)

        body = yield tool('subagent_resume', task_id=self.original_id,
                          message='FORK_TASK:RESUME Follow up on the original only.')
        body = yield wait_reply(body)
        assert 'ANSWER_RESUME' in last_output(body)
        contains(self.request_for('RESUME'), 'ANSWER_ORIGINAL', 'FORK_TASK:RESUME')
        excludes(self.request_for('RESUME'), 'ANSWER_BRANCH_A', 'ANSWER_BRANCH_B')
        resumed = checkpoint(self.root, self.original_id, 'ANSWER_RESUME')
        assert resumed[1] != original[1], 'resume did not update original'
        for branch in branches:
            unchanged(branch)

        if self.workflows:
            before = set(self.root.glob('.graff/sessions/*/workers/*.json'))
            body = yield tool('workflow', fork_from=source, retained=True, phases=[
                {'title': 'parallel', 'tasks': [
                    task('PHASE_A', 'Report the inventory of alpha.txt and beta.txt.'),
                    task('PHASE_B', 'Summarize the deployment configuration in gamma.txt.')]},
                {'title': 'synthesis', 'tasks': [task('SYNTHESIS', '{{prev}}')]}])
            assert 'ANSWER_SYNTHESIS' in last_output(body), last_output(body)
            for name in ('PHASE_A', 'PHASE_B', 'SYNTHESIS'):
                contains(self.request_for(name), 'ANSWER_ORIGINAL', 'ANSWER_RESUME')
            excludes(self.request_for('PHASE_A'), 'ANSWER_PHASE_B')
            excludes(self.request_for('PHASE_B'), 'ANSWER_PHASE_A')
            contains(self.request_for('SYNTHESIS'), 'ANSWER_PHASE_A', 'ANSWER_PHASE_B')
            self.workflow_records(before, ('PHASE_A', 'PHASE_B', 'SYNTHESIS'), ids)
            unchanged(resumed)

            before = set(self.root.glob('.graff/sessions/*/workers/*.json'))
            body = yield tool('workflow', fork_from=source, retained=True, pipeline={
                'isolation': 'shared_cwd', 'items': ['ALPHA', 'BETA'], 'stages': [
                    task('PIPE_{{item}}_ONE'), task('PIPE_{{item}}_TWO', '{{prev}}')]})
            for item, other in [('ALPHA', 'BETA'), ('BETA', 'ALPHA')]:
                for stage in ('ONE', 'TWO'):
                    request = self.request_for('PIPE_' + item + '_' + stage)
                    contains(request, 'ANSWER_ORIGINAL', 'ANSWER_RESUME')
                    excludes(request, 'ANSWER_PIPE_' + other + '_ONE',
                             'ANSWER_PIPE_' + other + '_TWO', 'ANSWER_SYNTHESIS')
                contains(self.request_for('PIPE_' + item + '_TWO'), 'ANSWER_PIPE_' + item + '_ONE')
            names = tuple('PIPE_' + item + '_' + stage
                          for item in ('ALPHA', 'BETA') for stage in ('ONE', 'TWO'))
            self.workflow_records(before, names, ids)
            unchanged(resumed)
        for branch in branches:
            unchanged(branch)
        unchanged(background)
        unchanged(self.saved[1])
        self.finished = True
        yield {'text': 'FORK_FIXTURE_DONE'}

    def workflow_records(self, before, names, ids):
        paths = set(self.root.glob('.graff/sessions/*/workers/*.json')) - before
        assert len(paths) == len(names), ('workflow checkpoint count', len(paths), names)
        found = set()
        for path in paths:
            record = json.loads(path.read_bytes())
            assert record['id'] not in ids and not record['pending']
            ids.add(record['id'])
            # Match the final assistant answer, not inherited task text or {{prev}}.
            final = next(m for m in reversed(record['messages']) if m.get('role') == 'assistant')
            matches = [name for name in names if 'ANSWER_' + name in text(final)]
            assert len(matches) == 1, final
            found.add(matches[0])
            assert 'ANSWER_ORIGINAL' in text(record['messages'])
        assert found == set(names), (found, names)


def acp_turn(binary, root, home, port, prompt):
    client = Acp(binary, root, home, port, extra_env=LOCAL_NETWORK_ENV)
    try:
        response = client.request('initialize', {'protocolVersion': 1})
        assert 'result' in response, response
        sid = client.request('session/new', {'cwd': str(root), 'mcpServers': []})['result']['sessionId']
        response = client.request('session/prompt', {'sessionId': sid,
            'prompt': [{'type': 'text', 'text': prompt}]}, timeout=120)
        assert response.get('result', {}).get('stopReason') == 'end_turn', response
        return sid
    finally:
        client.close()


def legacy_turn(binary, root, home, port, prompt):
    env = {k: v for k, v in os.environ.items()
           if not k.endswith('_API_KEY') and not k.startswith(('GRAFF_', 'HARNESS_'))}
    env.update(HOME=str(home), AI_GATEWAY_API_KEY='local', GRAFF_FLEET='off',
               GRAFF_VERCEL_URL=f'http://127.0.0.1:{port}/v1/chat/completions',
               GRAFF_NO_TELEMETRY='1', GRAFF_BEHAVIOR_UPLOAD='off',
               GRAFF_NO_SMOLIFY='1', NO_COLOR='1')
    env.update(LOCAL_NETWORK_ENV)
    done = subprocess.run([str(binary), '--json', '--yolo', '--old', '--no-lean', '--model', 'vercel'],
        cwd=root, env=env, input=json.dumps({'type': 'user', 'text': prompt}) + '\n',
        text=True, capture_output=True, timeout=120)
    assert done.returncode == 0, (done.stdout[-4000:], done.stderr[-2000:])


class ForeignModel(ScriptedModel):
    """A different parent must not fork a known id from another worker family."""
    def __init__(self, ident):
        super().__init__([spawn('FORBIDDEN', 'worker:' + ident), {'text': 'OWNERSHIP_DONE'}])

    def check(self):
        assert len(self.requests) == 2, 'foreign worker reached inference'
        result = last_output(self.requests[1])
        assert 'ANSWER_ORIGINAL' not in result
        # Another family resolves a different checkpoint path. Generic errors
        # (unknown tool, malformed arguments, exhausted budget) are not evidence
        # that ownership was enforced.
        assert any(code in result for code in ('FileNotFound', 'WorkerOwnershipMismatch')), result


def check(binary, surface):
    with tempfile.TemporaryDirectory(prefix='graff-subagent-fork-') as temporary:
        root = Path(temporary).resolve()
        home = root / 'home'
        home.mkdir()
        # Real independent fixture inputs admit a fleet through the normal R2 gate.
        for name in ('alpha.txt', 'beta.txt', 'gamma.txt'):
            (root / name).write_text('Synthetic fork fixture evidence.\n')
        source_model = ScriptedModel([{'text': 'ANSWER_SOURCE'}])
        port = source_model.start(0)
        try:
            sid = acp_turn(binary, root, home, port, 'FORK_TASK:SOURCE Preserve this evidence.')
            path = root / '.graff/sessions' / (sid + '.session.json')
            saved = (sid, (path, wait_file(path, 'ANSWER_SOURCE')))
        finally:
            source_model.stop()
        runner = acp_turn if surface == 'acp' else legacy_turn
        model = ForkModel(root, saved, workflows=surface == 'acp')
        port = model.start(0)
        try:
            runner(binary, root, home, port, 'FORK_TASK:ROOT Execute the supplied fork fixture tools.')
            assert not model.errors, model.errors
            assert model.finished, 'parent did not complete the assertions'
            # Ephemeral current/saved forks must not accidentally retain checkpoints.
            records = list(root.glob('.graff/sessions/*/workers/*.json'))
            assert len(records) == (11 if surface == 'acp' else 4), len(records)
            snapshots = [(p, p.read_bytes()) for p in records]
        finally:
            model.stop()
        foreign = ForeignModel(model.original_id)
        port = foreign.start(0)
        try:
            runner(binary, root, home, port, 'FORK_TASK:FOREIGN Try the supplied foreign worker fork.')
            foreign.check()
            for snapshot in snapshots:
                unchanged(snapshot)
            unchanged(saved[1])
        finally:
            foreign.stop()
    print('PASS ' + surface + ': fork requests, owned background worker, immutable sources, original resume'
          + (', retained phase/pipeline fan-out' if surface == 'acp' else ''))


if __name__ == '__main__':
    binary = Path(sys.argv[1] if len(sys.argv) > 1 else REPO / 'zig-out/bin/graff').resolve()
    for surface in ('acp', 'json'):
        check(binary, surface)
