#!/usr/bin/env python3
"""Bound synthesis on the real ACP/JSON engine using an offline mock model."""
import importlib.util
import json
from pathlib import Path
import re
import sys
import tempfile
import threading
import traceback

REPO = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('fork_fixture', REPO / 'scripts/test-subagent-fork.py')
fixture = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fixture)


def task(name, description=None):
    return {'description': description or name,
            'prompt': 'SYNTH_TASK:' + name + ' Run the supplied fixture commands for alpha.txt, beta.txt and gamma.txt, then report the evidence.',
            'isolation': 'shared_cwd'}


def workflow(name, pipeline=False):
    if pipeline:
        stages = [task('EVIDENCE', 'find'), task(name, 'synthesize')]
        return fixture.tool('workflow', pipeline={'items': ['alpha.txt'], 'stages': stages})
    return fixture.tool('workflow', phases=[
        {'title': 'find', 'tasks': [task('EVIDENCE_A'), task('EVIDENCE_B')]},
        {'title': 'synthesize', 'tasks': [task(name)]}])


class Model(fixture.ScriptedModel):
    def __init__(self, root):
        super().__init__([])
        self.root = root
        self.lock = threading.Lock()
        self.calls = {}
        self.errors = []
        self.finished = False
        self.started = False
        self.parent = self.sequence()

    def next_reply(self, body):
        super().next_reply(body)
        users = json.dumps([m.get('content', '') for m in body.get('messages', [])
                            if m.get('role') == 'user'])
        names = re.findall(r'SYNTH_TASK:([A-Z_]+)', users)
        with self.lock:
            try:
                assert names, 'missing task marker'
                name = names[-1]
                if name == 'ROOT':
                    if not self.started:
                        self.started = True
                        return next(self.parent)
                    return self.parent.send(body)
                calls = self.calls.setdefault(name, [])
                calls.append(body)
                n = len(calls)
                if name.startswith('EVIDENCE'):
                    return {'text': 'FINDING: EARLIER_VERIFIED_EVIDENCE from alpha.txt:1'}
                # Unique inputs and outputs deliberately avoid the identical-call
                # guard: synthesis must be bounded even while reads keep changing.
                if n <= (11 if name == 'GENERAL' else 8):
                    assert body.get('tools'), (name, n, 'tools withdrawn too early')
                    return fixture.tool('bash', command='printf UNIQUE_' + name + '_' + str(n))
                if name == 'GENERAL':
                    return {'text': 'GENERAL_DONE'}
                assert n == 9, (name, n, 'synthesis exceeded its request allowance')
                previous = calls[-2]
                assert body.get('tools') == previous['tools'], (name, 'report changed the tool catalog')
                assert body.get('tool_choice') == 'none', (name, 'report permits tool use')
                assert body['messages'][0] == previous['messages'][0], (name, 'report changed the system prefix')
                assert body.get('prompt_cache_key') == previous.get('prompt_cache_key'), (name, 'report changed cache routing')
                if name.startswith('BAD'):
                    return fixture.tool('bash', command='printf FORBIDDEN > forbidden-' + name + '.txt')
                return {'text': 'SYNTHESIS_DONE_' + name}
            except Exception:
                self.errors.append(traceback.format_exc())
                # Even the unfixed binary receives a final answer, never an
                # indefinitely repeating mock. The assertion below is the failure.
                return {'text': 'SYNTHESIS_FIXTURE_FAILED'}

    def sequence(self):
        for name, pipeline in [('NORMAL', False), ('BAD_PHASE', False), ('BAD_PIPELINE', True)]:
            body = yield workflow(name, pipeline)
            output = fixture.last_output(body)
            assert len(self.calls.get(name, [])) == 9, (name, len(self.calls.get(name, [])), output)
            if name.startswith('BAD'):
                assert 'WorkflowSynthesisLimit' in output, output
                assert 'EARLIER_VERIFIED_EVIDENCE' in output, output
                assert 'workflow incomplete' in output, output
                assert not (self.root / ('forbidden-' + name + '.txt')).exists()
            else:
                assert 'SYNTHESIS_DONE_NORMAL' in output, output
        body = yield fixture.tool('subagent', **dict(task('GENERAL'), run_in_background=False))
        assert len(self.calls.get('GENERAL', [])) == 12
        assert 'GENERAL_DONE' in fixture.last_output(body)
        self.finished = True
        yield {'text': 'SYNTHESIS_FIXTURE_DONE'}


def check(binary, surface):
    with tempfile.TemporaryDirectory(prefix='graff-synthesis-') as temporary:
        root = Path(temporary).resolve()
        home = root / 'home'
        home.mkdir()
        for name in ('alpha.txt', 'beta.txt', 'gamma.txt'):
            (root / name).write_text('Synthetic evidence.\n')
        model = Model(root)
        port = model.start(0)
        try:
            runner = fixture.acp_turn if surface == 'acp' else fixture.legacy_turn
            runner(binary, root, home, port,
                   'SYNTH_TASK:ROOT Audit alpha.txt, beta.txt and gamma.txt using the supplied workflow fixture.')
            assert not model.errors, '\n'.join(model.errors)
            assert model.finished, 'parent did not receive a final workflow result'
        finally:
            model.stop()
    print('PASS ' + surface + ': bounded synthesis, report-only dispatch, preserved findings, no retry, ordinary workers unchanged')


if __name__ == '__main__':
    binary = Path(sys.argv[1] if len(sys.argv) > 1 else REPO / 'zig-out/bin/graff').resolve()
    for surface in ('acp', 'json'):
        check(binary, surface)
