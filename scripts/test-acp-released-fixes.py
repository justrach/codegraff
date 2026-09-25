#!/usr/bin/env python3
"""Offline ACP integration: atomic edits and stale shell controls reach clients honestly."""
import argparse
import json
import os
from pathlib import Path
import queue
import re
import signal
import subprocess
import sys
import tempfile
import threading
import time

REPO = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPO / 'scripts/eval'))
from mock_model import ScriptedModel


def result_text(body):
    return [m.get('content', '') for m in body.get('messages', []) if m.get('role') == 'tool'][-1]


def tool(name, **arguments):
    return {'tool': name, 'arguments': arguments}


class Model(ScriptedModel):
    def __init__(self, workspace):
        super().__init__([])
        self.workspace = workspace
        self.handle = None
        self.error = None

    def next_reply(self, body):
        with self._lock:
            self.requests.append(body)
            n = len(self.requests)
        try:
            if n == 1:
                return tool('edit_file', path='proof.txt', edits=[
                    {'old_string': 'alpha', 'new_string': 'ALPHA'},
                    {'old_string': 'missing', 'new_string': 'BETA'}])
            if n == 2:
                assert (self.workspace / 'proof.txt').read_text() == 'alpha\nbeta\n'
                assert 'no batch changes written' in result_text(body)
                return tool('edit_file', path='proof.txt', edits=[
                    {'old_string': 'alpha', 'new_string': 'ALPHA'},
                    {'old_string': 'beta', 'new_string': 'BETA'}])
            if n == 3:
                assert (self.workspace / 'proof.txt').read_text() == 'ALPHA\nBETA\n'
                return {'text': 'Batch recovered.'}
            if n == 4:
                return tool('shell', action='run', command='printf ACP-LIVE-JOB; sleep 12', run_in_background=True)
            if n == 5:
                match = re.search(r'\[job (\d+) started:', result_text(body))
                assert match, result_text(body)
                self.handle = int(match.group(1))
                assert 2**32 <= self.handle <= 2**53 - 1
                time.sleep(.1)
                return tool('bash_output', id=1, wait_ms=0)
            if n == 6:
                assert 'no live owner' in result_text(body)
                assert 'ACP-LIVE-JOB' not in result_text(body)
                return tool('bash_kill', id=1)
            if n == 7:
                assert 'no process was stopped' in result_text(body)
                return tool('shell', action='output', id=self.handle, wait_ms=0)
            if n == 8:
                assert 'ACP-LIVE-JOB' in result_text(body), result_text(body)
                assert 'running' in result_text(body), result_text(body)
                return tool('shell', action='kill', id=self.handle)
            if n == 9:
                assert 'killed' in result_text(body), result_text(body)
                return {'text': 'Stale handles refused; live handle usable.'}
            if n == 10:
                return tool('read_file', path='proof.txt')
            if n == 11:
                assert 'ALPHA' in result_text(body) and 'BETA' in result_text(body)
                return {'text': 'Follow-up succeeded.'}
            raise AssertionError(f'unexpected model request {n}')
        except Exception as exc:
            self.error = repr(exc)
            return {'text': 'Fixture assertion failed.'}


def terminal_updates(events):
    return [e['params']['update'] for e in events if e.get('method') == 'session/update'
            and e.get('params', {}).get('update', {}).get('sessionUpdate') == 'tool_call_update'
            and e['params']['update'].get('status') in ('completed', 'failed')
            and e['params']['update'].get('content')]


def text(update):
    return ''.join(c.get('content', {}).get('text', '') for c in update.get('content', []))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('binary', type=Path, nargs='?', default=REPO / 'zig-out/bin/graff')
    parser.add_argument('--capture', type=Path, help='Write real ACP updates for offline client reducer tests')
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix='graff-acp-released-') as temporary:
        workspace = Path(temporary)
        (workspace / 'proof.txt').write_text('alpha\nbeta\n')
        config = workspace / 'mcp.json'
        config.write_text('{"mcpServers":{}}')
        model = Model(workspace)
        port = model.start(0)
        env = {k: v for k, v in os.environ.items() if not k.endswith('_API_KEY') and not k.startswith(('GRAFF_', 'HARNESS_'))}
        env.update(HOME=temporary, AI_GATEWAY_API_KEY='local', GRAFF_VERCEL_URL=f'http://127.0.0.1:{port}/v1/chat/completions',
                   GRAFF_MCP_CONFIG=str(config), GRAFF_NO_TELEMETRY='1', GRAFF_FLEET='off', GRAFF_NO_SMOLIFY='1',
                   GRAFF_NO_CODEDB_GUARD='1', GRAFF_BEHAVIOR_UPLOAD='off', NO_COLOR='1')
        process = None
        captured = []
        try:
            with (workspace / 'stderr.log').open('w+') as stderr:
                process = subprocess.Popen([str(args.binary.resolve()), 'acp', '--model', 'vercel', '--yolo', '--old', '--no-lean'],
                    cwd=workspace, env=env, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=stderr, text=True, start_new_session=True)
                messages = queue.Queue()
                def reader():
                    for line in process.stdout:
                        try: messages.put(json.loads(line))
                        except ValueError: pass
                    messages.put(None)
                threading.Thread(target=reader, daemon=True).start()
                def call(method, params, identifier):
                    process.stdin.write(json.dumps(dict(jsonrpc='2.0', method=method, params=params, id=identifier)) + '\n')
                    process.stdin.flush()
                    updates = []
                    deadline = time.monotonic() + 30
                    while True:
                        message = messages.get(timeout=max(.01, deadline - time.monotonic()))
                        assert message is not None, 'ACP exited before responding'
                        captured.append(message)
                        if message.get('id') == identifier:
                            assert 'error' not in message, message
                            return message.get('result', {}), updates
                        updates.append(message)
                init, _ = call('initialize', {'protocolVersion': 1}, 1)
                assert init.get('protocolVersion') == 1, init
                session, _ = call('session/new', {'cwd': temporary, 'mcpServers': []}, 2)
                sid = session['sessionId']
                def prompt(message, identifier):
                    result, updates = call('session/prompt', {'sessionId': sid, 'prompt': [{'type': 'text', 'text': message}]}, identifier)
                    assert result.get('stopReason') == 'end_turn', result
                    assert model.error is None, model.error
                    return updates
                turn = prompt('Apply the scripted batch, correct its invalid span, then finish.', 3)
                edits = terminal_updates(turn)
                assert len(edits) == 1 and edits[0]['status'] == 'failed', edits
                assert 'no batch changes written' in text(edits[0])
                # #1287: a successful native edit keeps its announced diff, so
                # its completion carries status only (content would replace it).
                updates = [e['params']['update'] for e in turn if e.get('method') == 'session/update']
                done = [u for u in updates if u.get('sessionUpdate') == 'tool_call_update' and u.get('status') == 'completed' and not u.get('content')]
                assert done, updates
                announced = {u['toolCallId']: u for u in updates if u.get('sessionUpdate') == 'tool_call'}
                diffs = [c for c in announced[done[-1]['toolCallId']].get('content') or [] if c.get('type') == 'diff']
                assert len(diffs) == 2, announced[done[-1]['toolCallId']]
                shell = terminal_updates(prompt('Start a job; reject legacy output and kill handles, then read and stop the valid handle.', 4))
                assert len(shell) == 5, shell
                assert shell[1]['status'] == shell[2]['status'] == 'failed', shell
                assert 'no live owner' in text(shell[1]) and 'no process was stopped' in text(shell[2])
                assert 'ACP-LIVE-JOB' not in text(shell[1])
                assert shell[3]['status'] == 'completed' and 'ACP-LIVE-JOB' in text(shell[3]), shell[3]
                follow = terminal_updates(prompt('Read the edited file and confirm the session still works.', 5))
                assert len(follow) == 1 and follow[0]['status'] == 'completed', follow
                assert len(model.requests) == 11
                if args.capture:
                    args.capture.parent.mkdir(parents=True, exist_ok=True)
                    fd = os.open(args.capture, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
                    with os.fdopen(fd, 'w') as output:
                        json.dump({'edit': edits, 'shell': shell, 'follow': follow, 'messages': captured}, output, indent=2)
                print('PASS ACP: atomic edit failure/recovery, stale shell controls failed, live u64 handle usable, follow-up succeeded')
        finally:
            if process:
                if process.poll() is None:
                    process.stdin.close()
                    try: process.wait(timeout=4)
                    except subprocess.TimeoutExpired:
                        os.killpg(process.pid, signal.SIGKILL)
                        process.wait(timeout=2)
                process.stdout.close()
            model.stop()


if __name__ == '__main__':
    main()
