#!/usr/bin/env python3
"""Offline bare line-REPL lifecycle eval; no pager or terminal window is opened."""
import argparse
import json
import os
from pathlib import Path
import pty
import select
import signal
import sys
import tempfile
import time

sys.path.insert(0, str(Path(__file__).parent / 'eval'))
from mock_model import ScriptedModel


class Model(ScriptedModel):
    def __init__(self):
        super().__init__([])
        self.parent_steps = 0
        self.child_steps = 0

    def next_reply(self, body):
        super().next_reply(body)
        users = [m.get('content', '') for m in body.get('messages', []) if m.get('role') == 'user']
        if not body.get('tools'):
            return {'text': 'Fixture task'}
        child = bool(users and 'CHILD_REPL_FIXTURE' in str(users[0]))
        if child:
            self.child_steps += 1
            if self.child_steps == 1:
                return {'tool': 'bash', 'arguments': {'command': 'touch child-ready; while [ ! -f child-release ]; do sleep 0.05; done; printf CHILD_TOOL_DONE'}}
            return {'text': 'CHILD_REPORT_READY'}
        self.parent_steps += 1
        if self.parent_steps == 1:
            # No run_in_background flag: interactive delegation must just work.
            return {'tool': 'subagent', 'arguments': {'description': 'fixture child', 'prompt': 'CHILD_REPL_FIXTURE: run the supplied fixture command and report.'}}
        if self.parent_steps == 2:
            assert 'PARENT_OTHER_TASK' in json.dumps(users[-1]), 'parent continued without new input'
            return {'text': 'OTHER_TASK_DONE'}
        if self.parent_steps == 3:
            assert 'agent 1 completed' in json.dumps(users), 'missing completion wake'
            return {'tool': 'agent_output', 'arguments': {'id': 1}}
        assert 'CHILD_REPORT_READY' in json.dumps(body), 'missing child report'
        return {'text': 'COLLECTED_CHILD_REPORT'}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--graff', default='./zig-out/bin/graff')
    args = parser.parse_args()
    binary = str(Path(args.graff).resolve())
    model = Model()
    model.start(1234)
    try:
        with tempfile.TemporaryDirectory(prefix='graff-repl-eval-') as tmp:
            workspace = Path(tmp)
            pid, fd = pty.fork()
            if pid == 0:
                os.chdir(tmp)
                env = {k: v for k, v in os.environ.items() if not k.endswith('_API_KEY') and k not in ('NO_COLOR', 'CLICOLOR')}
                env.update(HOME=tmp, PWD=tmp, TERM='xterm-256color', LMSTUDIO_API_KEY='local', GRAFF_NO_TELEMETRY='1', GRAFF_FLEET='off', GRAFF_NO_SMOLIFY='1')
                os.execve(binary, [binary, '--model', 'lmstudio', '--yolo', '--old'], env)
            output = bytearray()
            first = second = released = False
            prompt_ready_at = None
            last_cursor_reply = 0.0
            deadline = time.monotonic() + 60
            try:
                while time.monotonic() < deadline:
                    if select.select([fd], [], [], 0.1)[0]:
                        try:
                            chunk = os.read(fd, 65536)
                        except OSError:
                            break
                        if not chunk:
                            break
                        output.extend(chunk)
                        if b'\x1b[6n' in chunk:
                            os.write(fd, b'\x1b[1;1R')
                            last_cursor_reply = time.monotonic()
                    text = output.decode(errors='replace')
                    if prompt_ready_at is None and ('\u203a' in text or '\u276f' in text):
                        prompt_ready_at = time.monotonic() + 0.2
                    if not first and prompt_ready_at is not None and time.monotonic() >= prompt_ready_at:
                        os.write(fd, b'PARENT_BACKGROUND_EVAL\r')
                        first = True
                    if first and not second and 'keep using the prompt' in text and (workspace / 'child-ready').exists() and time.monotonic() - last_cursor_reply > 0.2:
                        os.write(fd, b'PARENT_OTHER_TASK\r')
                        second = True
                    if second and not released and 'OTHER_TASK_DONE' in text:
                        assert not (workspace / 'child-release').exists()
                        assert model.child_steps == 1, 'child finished before other task'
                        (workspace / 'child-release').touch()
                        released = True
                    if released and 'COLLECTED_CHILD_REPORT' in text:
                        assert model.parent_steps == 4, f'unexpected parent calls: {model.parent_steps}'
                        assert model.child_steps == 2
                        print('pass: default background spawn, independent parent turn, automatic completion wake, report collection')
                        return
                raise AssertionError('REPL lifecycle did not complete:\n' + output.decode(errors='replace')[-5000:] + '\nREQUESTS: ' + json.dumps([{'users': [m.get('content') for m in r.get('messages', []) if m.get('role') == 'user']} for r in model.requests])[-3000:])
            finally:
                (workspace / 'child-release').touch()
                try:
                    os.killpg(pid, signal.SIGTERM)
                except ProcessLookupError:
                    pass
                os.close(fd)
                os.waitpid(pid, 0)
    finally:
        model.stop()


if __name__ == '__main__':
    main()
