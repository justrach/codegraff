#!/usr/bin/env python3
"""Offline ACP background-child stream across parent prompt boundaries."""
import importlib.util
import json
import queue
import subprocess
import sys
import tempfile
import threading
import time
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('acp_load', REPO / 'scripts/test-acp-session-load.py')
load = importlib.util.module_from_spec(spec)
spec.loader.exec_module(load)


class Model(load.ScriptedModel):
    def __init__(self):
        super().__init__([], exhausted_text='unexpected model request')
        self.child_started = threading.Event()
        self.release_child = threading.Event()
        self.child_reply_ready = threading.Event()
        self.child_frame_sent = threading.Event()
        self.root_calls = 0

    def after_stream_delta(self, _delta):
        if self.child_reply_ready.is_set():
            self.child_frame_sent.set()

    def next_reply(self, body):
        names = [item.get('function', item).get('name') for item in body.get('tools', [])]
        with self._lock:
            self.requests.append(body)
            if 'subagent' in names:
                self.root_calls += 1
                number = self.root_calls
            elif names:
                number = 0
            else:
                return {'text': 'Short title'}
        if number == 0:
            self.child_started.set()
            assert self.release_child.wait(15), 'child release timed out'
            self.child_reply_ready.set()
            return {'text': 'The child finished after the parent prompt.'}
        if number == 1:
            return {'tool': 'subagent', 'arguments': {
                'description': 'Inspect in background', 'prompt': 'Return a short report.',
                'isolation': 'shared_cwd', 'run_in_background': True}}
        return {'text': 'Parent turn finished while child runs.'}


def drain_until(client, predicate, timeout=8):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        while b'\n' in client.pending:
            line, client.pending = client.pending.split(b'\n', 1)
            event = json.loads(line)  # A torn/interleaved JSON frame fails here.
            client.events.append(event)
            if predicate(event):
                return event
        try:
            chunk = client.chunks.get(timeout=.1)
        except queue.Empty:
            continue
        assert chunk is not None, 'ACP exited before child terminal state'
        client.pending += chunk
    raise AssertionError('background child notification timed out')


def child_events(client):
    return [row['params'] for row in client.events if row.get('method') == 'graff/subagent_event']


def run(binary, capability=True, cancel=False, disconnect=False, switch_session=False):
    with tempfile.TemporaryDirectory(prefix='graff-acp-background-') as temporary:
        work = Path(temporary)
        home = work / 'home'
        home.mkdir()
        other_sid = None
        if switch_session:
            seed_model = load.ScriptedModel([])
            seed_port = seed_model.start(0)
            seed = load.Acp(binary, work, home, seed_port, extra_env={'GRAFF_NO_NATIVE_FOLD': '1'})
            try:
                seed.request('initialize', {'protocolVersion': 1})
                other_sid = seed.request('session/new', {'cwd': str(work), 'mcpServers': []})['result']['sessionId']
            finally:
                seed.close()
                seed_model.stop()
            assert (work / '.graff' / 'sessions' / f'{other_sid}.session.json').exists()
        model = Model()
        port = model.start(0)
        extra_env = {'GRAFF_NO_NATIVE_FOLD': '1'}
        if disconnect:
            extra_env['GRAFF_SHUTDOWN_DEBUG'] = '1'
        client = load.Acp(binary, work, home, port, extra_env=extra_env,
                          extra_args=('--max-model-calls', '6', '--max-run-tool-calls', '8'))
        try:
            caps = {'_meta': {'graff/backgroundSubagents': True}} if capability else {}
            init = client.request('initialize', {'protocolVersion': 1, 'clientCapabilities': caps})
            assert init['result']['agentCapabilities']['_meta']['graff/backgroundSubagents'] is True
            sid = client.request('session/new', {'cwd': str(work), 'mcpServers': []})['result']['sessionId']
            first = client.request('session/prompt', {'sessionId': sid,
                'prompt': [{'type': 'text', 'text': 'Delegate in the background.'}]}, timeout=15)
            assert first['result']['stopReason'] == 'end_turn', first
            assert model.child_started.wait(8), 'child did not start'
            assert not model.release_child.is_set()
            second = client.request('session/prompt', {'sessionId': sid,
                'prompt': [{'type': 'text', 'text': 'Continue while the child runs.'}]}, timeout=15)
            assert second['result']['stopReason'] == 'end_turn', second
            rows = child_events(client)
            if not capability:
                assert not rows, rows
                return
            assert rows and rows[0]['event']['type'] == 'spawn', rows
            spawn = rows[0]
            assert spawn['parentSessionId'] == sid and spawn['seq'] == 0, spawn
            assert spawn['parentToolCallId'], spawn
            assert all(row['subagentSessionId'] == spawn['subagentSessionId'] and
                       row['parentToolCallId'] == spawn['parentToolCallId'] for row in rows), rows
            assert not any(row['event']['type'] == 'terminal' for row in rows), rows
            if switch_session:
                assert other_sid != sid
                loaded = client.request('session/load', {'sessionId': other_sid,
                    'cwd': str(work), 'mcpServers': []})
                assert 'result' in loaded, loaded
                # Reinitialization may disable future children; this child was
                # already announced and must retain its stream and parent ID.
                client.request('initialize', {'protocolVersion': 1, 'clientCapabilities': {}})
            if disconnect:
                client.proc.stdin.close()
                # ACP detaches its emitter before waiting for the held worker
                # during process teardown. Releasing it afterward must not
                # write a frame into the closed connection.
                time.sleep(.2)
                model.release_child.set()
                # Shutdown joins a still-running worker. On a loaded Windows
                # runner, its request/cleanup can outlast an eight-second
                # process deadline; the fixture itself bounds the held model
                # request at 15 seconds. Keep the stronger exit assertion,
                # and name the shutdown phase if it really stalls.
                try:
                    exit_code = client.proc.wait(timeout=25)
                except subprocess.TimeoutExpired as exc:
                    trace = Path(client.err.name).read_text(errors='replace')[-3000:]
                    state = (f'child_started={model.child_started.is_set()} '
                             f'released={model.release_child.is_set()} '
                             f'reply_ready={model.child_reply_ready.is_set()} '
                             f'frame_sent={model.child_frame_sent.is_set()} '
                             f'model_requests={len(model.requests)}')
                    raise AssertionError(f'ACP did not exit after stdin EOF ({state}); stderr tail:\n{trace}') from exc
                assert exit_code == 0, exit_code
                while True:
                    try:
                        chunk = client.chunks.get_nowait()
                    except queue.Empty:
                        break
                    if chunk is not None:
                        client.pending += chunk
                while b'\n' in client.pending:
                    line, client.pending = client.pending.split(b'\n', 1)
                    client.events.append(json.loads(line))
                assert not client.pending, 'partial JSON frame on ACP teardown'
                assert not any(row['event']['type'] == 'terminal' for row in child_events(client))
                return
            if cancel:
                agents = client.request('graff/agents', {'action': 'list', 'scope': 'device'})
                parent = next(row for row in agents['result']['agents'] if row['session'] == sid)
                client.request('graff/agents', {'action': 'cancel', 'scope': 'device',
                    'target': sid, 'startId': parent['startId'],
                    'child': spawn['subagentSessionId']})
            model.release_child.set()
            terminal = drain_until(client, lambda row: row.get('method') == 'graff/subagent_event'
                and row['params']['event']['type'] == 'terminal')
            assert terminal['params']['event']['state'] == ('cancelled' if cancel else 'completed')
            rows = child_events(client)
            assert all(row['parentSessionId'] == sid for row in rows), rows
            assert [row['seq'] for row in rows] == list(range(len(rows))), rows
            assert rows[-1]['event']['type'] == 'terminal', rows
            assert rows[-1]['seq'] > 0, rows
        finally:
            model.release_child.set()
            client.close()
            model.stop()


if __name__ == '__main__':
    binary = Path(sys.argv[1] if len(sys.argv) > 1 else REPO / 'zig-out/bin/graff').resolve()
    run(binary, capability=False)
    run(binary)
    run(binary, cancel=True)
    run(binary, disconnect=True)
    run(binary, switch_session=True)
    print('ACP background subagents: opt-in, cross-turn stream, session switch, cancellation, ordered JSON frames, teardown')
