#!/usr/bin/env python3
"""Offline real ACP: transport retry/failure preserve usage uncertainty on the wire."""
import argparse
import json
import os
from pathlib import Path
import queue
import subprocess
import tempfile
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('binary', type=Path)
    parser.add_argument('--capture', type=Path)
    args = parser.parse_args()
    requests = []

    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *_):
            pass

        def do_POST(self):
            requests.append(json.loads(self.rfile.read(int(self.headers['Content-Length']))))
            if len(requests) != 2:
                # Complete request accepted, no response headers: outer retry is observable.
                self.close_connection = True
                return
            chunks = [
                {'choices': [{'index': 0, 'delta': {'content': 'Recovered.'}, 'finish_reason': None}]},
                {'choices': [{'index': 0, 'delta': {}, 'finish_reason': 'stop'}],
                 'usage': {'prompt_tokens': 10, 'completion_tokens': 2, 'total_tokens': 12}},
            ]
            payload = ''.join('data: ' + json.dumps(c) + '\n\n' for c in chunks) + 'data: [DONE]\n\n'
            data = payload.encode()
            self.send_response(200)
            self.send_header('Content-Type', 'text/event-stream')
            self.send_header('Content-Length', str(len(data)))
            self.end_headers()
            self.wfile.write(data)

    server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    captured = []
    try:
        with tempfile.TemporaryDirectory(prefix='graff-acp-usage-') as tmp:
            config = Path(tmp)/'mcp.json'
            config.write_text('{"mcpServers":{}}')
            env = {k: v for k, v in os.environ.items() if not k.endswith('_API_KEY') and not k.startswith(('GRAFF_', 'HARNESS_'))}
            env.update(HOME=tmp, AI_GATEWAY_API_KEY='local', GRAFF_VERCEL_URL=f'http://127.0.0.1:{server.server_port}/v1/chat/completions',
                       GRAFF_MCP_CONFIG=str(config), GRAFF_NO_TELEMETRY='1', GRAFF_FLEET='off', GRAFF_NO_SMOLIFY='1',
                       GRAFF_NO_CODEDB_GUARD='1', GRAFF_BEHAVIOR_UPLOAD='off', NO_COLOR='1')
            with (Path(tmp)/'stderr').open('w') as stderr:
                process = subprocess.Popen([str(args.binary.resolve()), 'acp', '--model', 'vercel', '--yolo', '--old', '--no-lean'],
                    cwd=tmp, env=env, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=stderr, text=True)
                messages = queue.Queue()
                def reader():
                    for line in process.stdout:
                        try: messages.put(json.loads(line))
                        except ValueError: pass
                    messages.put(None)
                threading.Thread(target=reader, daemon=True).start()
                def call(method, params, identifier):
                    process.stdin.write(json.dumps(dict(jsonrpc='2.0', id=identifier, method=method, params=params))+'\n')
                    process.stdin.flush()
                    events = []
                    while True:
                        message = messages.get(timeout=40)
                        assert message is not None, 'ACP exited without terminal reply'
                        captured.append(message)
                        if message.get('id') == identifier: return message, events
                        events.append(message)
                try:
                    initialized, _ = call('initialize', {'protocolVersion': 1}, 1)
                    assert initialized['result']['agentCapabilities']['_meta']['codegraff/usage'] is True
                    reply, _ = call('session/new', {'cwd': tmp, 'mcpServers': []}, 2)
                    sid = reply['result']['sessionId']
                    prompt = {'sessionId': sid, 'prompt': [{'type': 'text', 'text': 'Reply briefly.'}]}
                    reply, events = call('session/prompt', prompt, 3)
                    assert reply['result']['stopReason'] == 'end_turn', reply
                    updates = [e['params']['update'] for e in events if e.get('method') == 'session/update']
                    usage = [e['params']['usage'] for e in events if e.get('method') == '_codegraff/usage']
                    assert len(usage) == 1 and usage[0]['unreported_failed_attempts'] == 1, usage
                    assert usage[0]['api_calls'] == 1 and usage[0]['input_tokens'] == 10, usage
                    assert not usage[0]['usage_complete'] and usage[0]['cost_usd'] is None, usage
                    assert any('network error:' in u.get('content', {}).get('text', '') for u in updates), updates
                    assert len(requests) == 2, len(requests)
                    reply, events = call('session/prompt', prompt, 4)
                    assert 'error' in reply, reply
                    usage = [e['params']['usage'] for e in events if e.get('method') == '_codegraff/usage']
                    assert len(usage) == 1 and usage[0]['unreported_failed_attempts'] == 7, usage
                    assert usage[0]['api_calls'] == 1 and usage[0]['cost_usd'] is None, usage
                    assert len(requests) == 8, len(requests)
                    if args.capture:
                        args.capture.write_text(''.join(json.dumps(e)+'\n' for e in captured))
                    print('PASS real ACP: retry then success, exhausted retry, known usage retained, total cost unknown')
                finally:
                    process.stdin.close()
                    try: process.wait(timeout=5)
                    except subprocess.TimeoutExpired: process.kill(); process.wait()
    finally:
        server.shutdown()
        server.server_close()


if __name__ == '__main__':
    main()
