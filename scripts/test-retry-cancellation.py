#!/usr/bin/env python3
"""Offline retry/cancel races: ACP v1/v2 and JSON, transport/429/503 failures.

Uses ephemeral loopback ports and isolated homes. No real credentials or model
calls. A retry trace row synchronizes cancellation with the actual backoff.
"""
import hashlib
import http.server
import json
import os
from pathlib import Path
import queue
import signal
import socket
import subprocess
import sys
import tempfile
import threading
import time

class Model:
    def __init__(self, kind, failures=-1, delay_ms=30000):
        self.kind, self.failures, self.delay_ms = kind, failures, delay_ms
        self.lock = threading.Lock()
        self.posts = []
        model = self

        class Handler(http.server.BaseHTTPRequestHandler):
            protocol_version = 'HTTP/1.1'

            def log_message(self, *_args):
                pass

            def do_GET(self):
                self.respond(200, b'{"data":[{"id":"fixture"}]}', 'application/json')

            def respond(self, status, body, content_type):
                self.send_response(status)
                self.send_header('content-type', content_type)
                self.send_header('content-length', str(len(body)))
                self.send_header('connection', 'close')
                if status in (429, 503):
                    self.send_header('retry-after-ms', str(model.delay_ms))
                self.end_headers()
                try:
                    self.wfile.write(body)
                    self.wfile.flush()
                except (BrokenPipeError, ConnectionResetError):
                    pass
                self.close_connection = True

            def do_POST(self):
                body = self.rfile.read(int(self.headers['content-length']))
                with model.lock:
                    model.posts.append((hashlib.sha256(body).hexdigest(), time.monotonic()))
                    fail = model.failures != 0
                    if model.failures > 0:
                        model.failures -= 1
                if fail and model.kind == 'transport':
                    self.close_connection = True
                    self.connection.shutdown(socket.SHUT_RDWR)
                    self.connection.close()
                elif fail:
                    self.respond(int(model.kind), b'{"error":{"message":"fixture transient failure"}}', 'application/json')
                else:
                    reply = ('data: {"choices":[{"index":0,"delta":{"content":"OK"},"finish_reason":null}]}\n\n'
                             'data: {"choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}\n\n'
                             'data: [DONE]\n\n').encode()
                    self.respond(200, reply, 'text/event-stream')

        self.server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()

    def recover(self):
        with self.lock:
            self.failures = 0

    def requests(self):
        with self.lock:
            return list(self.posts)

    def close(self):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(timeout=5)


class Client:
    def __init__(self, binary, root, model, mode):
        self.root, self.mode = root, mode
        self.seen, self.events = [], queue.Queue()
        self.counter = 0
        self.sid = None
        (root/'mcp.json').write_text('{"mcpServers":{}}')
        shim = root/'bin'
        shim.mkdir()
        (shim/'security').write_text('#!/bin/sh\nexit 44\n')
        (shim/'security').chmod(0o700)
        env = dict(HOME=str(root), USERPROFILE=str(root),
                   PATH=str(shim)+os.pathsep+os.defpath, TERM='dumb',
                   AI_GATEWAY_API_KEY='fixture', GRAFF_NO_TELEMETRY='1',
                   GRAFF_VERCEL_URL=f'http://127.0.0.1:{model.server.server_port}/v1/chat/completions',
                   GRAFF_MCP_CONFIG=str(root/'mcp.json'), GRAFF_FLEET='off',
                   GRAFF_NO_ADOPT='1', GRAFF_NO_SMOLIFY='1', GRAFF_NO_CODEDB_GUARD='1')
        if 'SystemRoot' in os.environ:
            env['SystemRoot'] = os.environ['SystemRoot']
        if mode == 'acp2':
            env['GRAFF_ACP_V2'] = '1'
        args = [str(binary), '--json'] if mode == 'json' else [str(binary), 'acp']
        self.stderr = (root/'stderr').open('w')
        self.proc = subprocess.Popen(args + ['--model', 'vercel', '--yolo'],
                                     cwd=root, env=env, stdin=subprocess.PIPE,
                                     stdout=subprocess.PIPE, stderr=self.stderr,
                                     text=True, start_new_session=os.name == 'posix')

        def read():
            try:
                for line in self.proc.stdout:
                    self.events.put(json.loads(line))
            except Exception as error:
                self.events.put(error)
            finally:
                self.events.put(None)
        self.reader = threading.Thread(target=read, daemon=True)
        self.reader.start()
        try:
            if mode != 'json':
                init = self.call('initialize', {'protocolVersion':2 if mode == 'acp2' else 1})
                assert init['result']['protocolVersion'] == (2 if mode == 'acp2' else 1), init
                self.sid = self.call('session/new', {'cwd':str(root), 'mcpServers':[]})['result']['sessionId']
        except BaseException:
            self.close()
            raise

    def send(self, value):
        self.proc.stdin.write(json.dumps(value) + '\n')
        self.proc.stdin.flush()

    def request(self, method, params):
        self.counter += 1
        self.send(dict(jsonrpc='2.0', id=self.counter, method=method, params=params))
        return self.counter

    def until(self, predicate, timeout=8):
        deadline = time.monotonic() + timeout
        while True:
            value = self.events.get(timeout=max(.01, deadline-time.monotonic()))
            assert isinstance(value, dict), ('invalid/closed protocol stream', value)
            self.seen.append(value)
            if predicate(value):
                return value
            assert time.monotonic() < deadline, ('protocol deadline', self.seen[-3:])

    def call(self, method, params):
        identifier = self.request(method, params)
        return self.until(lambda value: value.get('id') == identifier)

    def trace(self):
        return [json.loads(line) for path in (self.root/'.graff/traces').glob('*.jsonl')
                for line in path.read_text().splitlines(keepends=True) if line.endswith('\n')]

    def begin(self):
        self.start = len(self.seen)
        self.retry_count = sum(row.get('ev') == 'retry' for row in self.trace())
        if self.mode == 'json':
            self.send({'type':'user', 'text':'Say OK.'})
            return None
        return self.request('session/prompt', {'sessionId':self.sid, 'prompt':[{'type':'text', 'text':'Say OK.'}]})

    def wait_retry(self):
        deadline = time.monotonic() + 8
        while sum(row.get('ev') == 'retry' for row in self.trace()) <= self.retry_count:
            assert self.proc.poll() is None, 'worker exited before retry'
            assert time.monotonic() < deadline, 'retry backoff not reached'
            time.sleep(.01)

    def cancel(self, wrong=False, client=False):
        if self.mode == 'json':
            self.send({'type':'cancel'})
        else:
            params = {'sessionId':'unrelated-session' if wrong else self.sid}
            if client:
                params['_meta'] = {'graff/cancelSource':'client'}
            self.send(dict(jsonrpc='2.0', method='session/cancel', params=params))

    def finish(self, identifier, cancelled=False):
        if self.mode == 'json':
            value = self.until(lambda event: event.get('type') in ('error', 'turn'))
            assert value.get('type') == ('error' if cancelled else 'turn'), value
            assert value.get('message' if cancelled else 'text') == ('turn cancelled' if cancelled else 'OK'), value
        elif self.mode == 'acp2':
            value = self.until(lambda event: event.get('params', {}).get('update', {}).get('state') == 'idle')
            assert value['params']['update']['stopReason'] == ('cancelled' if cancelled else 'end_turn'), value
            acks = [event for event in self.seen[self.start:] if event.get('id') == identifier]
            assert len(acks) == 1 and acks[0].get('result', {}).get('messageId'), acks
        else:
            value = self.until(lambda event: event.get('id') == identifier)
            assert value.get('result', {}).get('stopReason') == ('cancelled' if cancelled else 'end_turn'), value
        wire = self.seen[self.start:]
        assert not any(token in json.dumps(wire) for token in ('network error:', 'retrying in', '· retry')), wire
        if self.mode == 'json':
            sequences = [event['seq'] for event in self.seen]
            assert sequences == list(range(sequences[0], sequences[0] + len(sequences))), sequences
        return value

    def saved(self):
        return [message for path in (self.root/'.graff/sessions').glob('*.session.json')
                for message in json.loads(path.read_text()).get('messages', [])]

    def close(self):
        if self.proc.poll() is None:
            try:
                if os.name == 'posix':
                    os.killpg(self.proc.pid, signal.SIGKILL)
                else:
                    self.proc.kill()
            except ProcessLookupError:
                pass
        self.proc.wait(timeout=8)
        self.reader.join(timeout=5)
        assert not self.reader.is_alive(), 'protocol reader did not stop'
        for stream in (self.proc.stdin, self.proc.stdout):
            stream.close()
        self.stderr.close()


def exercise(binary, mode, kind, scenario):
    with tempfile.TemporaryDirectory(prefix='graff-retry-cancel-') as temp:
        model = Model(kind, failures=1 if scenario == 'wrong' else -1,
                      delay_ms=500 if scenario == 'wrong' else 30000)
        client = None
        try:
            client = Client(binary, Path(temp), model, mode)
            marker = None
            identifier = client.begin()
            if scenario == 'immediate':
                client.cancel()
            else:
                client.wait_retry()
                assert len(model.requests()) == 1, 'unexpected retry before cancellation'
                client.cancel(wrong=scenario == 'wrong', client=scenario == 'client')
                client.cancel(wrong=scenario == 'wrong', client=scenario == 'client')
            started = time.monotonic()
            client.finish(identifier, cancelled=scenario != 'wrong')
            elapsed = time.monotonic() - started
            if scenario == 'wrong':
                posts = model.requests()
                assert len(posts) == 2 and posts[0][0] == posts[1][0], posts
                if kind != 'transport':
                    assert posts[1][1] - posts[0][1] >= .45, 'Retry-After bypassed'
            else:
                assert elapsed < 2, ('cancel waited out backoff', elapsed)
                assert len(model.requests()) <= 1, model.requests()
                source = 'json_cancel' if mode == 'json' else 'acp_client' if scenario == 'client' else 'acp_cancel'
                if scenario != 'immediate':
                    assert f'interrupted source={source}' in json.dumps(client.trace()), source
                    marker = 'stopped by the client, not the user' if scenario == 'client' else 'interrupted by user'
            if scenario == 'eof':
                # The documented checkpoint boundary is graceful exit: JSON may
                # publish its error before the synchronous save has returned.
                client.proc.stdin.close()
                assert client.proc.wait(timeout=8) == 0, 'worker did not exit cleanly'
                assert marker in json.dumps(client.saved()), ('cancelled history lost at EOF', client.saved())
                assert len(model.requests()) == 1, 'EOF dispatched another retry'
                print(f'PASS {mode}/{kind}/eof: graceful exit drains the cancelled checkpoint', flush=True)
                return
            # Duplicate/late cancels while idle must not poison the next turn.
            client.cancel()
            client.cancel()
            model.recover()
            before = len(model.requests())
            followup = client.begin()
            client.finish(followup)
            assert len(model.requests()) == before + 1, 'follow-up was lost or replayed'
            # JSON emits its error before persisting history. The next completed
            # turn is a barrier proving the prior interrupted turn was saved.
            if marker:
                assert marker in json.dumps(client.saved()), (scenario, client.saved())
            print(f'PASS {mode}/{kind}/{scenario}: correct scope, clean wire, same-worker continuation', flush=True)
        finally:
            if client:
                client.close()
            model.close()


def main():
    binary = Path(sys.argv[1] if len(sys.argv) > 1 else 'zig-out/bin/graff').resolve()
    cases = [(mode, kind, 'cancel') for mode in ('acp1', 'acp2', 'json')
             for kind in ('transport', '429', '503')]
    cases += [(mode, kind, 'wrong') for mode in ('acp1', 'acp2') for kind in ('transport', '429')]
    cases += [(mode, '503', 'immediate') for mode in ('acp1', 'acp2', 'json')]
    cases += [(mode, '429', 'client') for mode in ('acp1', 'acp2')]
    cases += [(mode, '503', 'eof') for mode in ('acp1', 'acp2', 'json')]
    for case in cases:
        exercise(binary, *case)
    print(f'PASS retry cancellation matrix: {len(cases)} scenarios', flush=True)


if __name__ == '__main__':
    main()
