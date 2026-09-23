#!/usr/bin/env python3
"""ACP -> production HTTPS SSE -> TLS/ALPN h2 -> local provider integration.

The pinned http-zig Session exposes no custom-CA API. Build an isolated binary
against a verified copy of that exact dependency, with ONE additive CA load
after the normal system trust scan. TLS hostname/signature checks, transport,
ACP dispatch, and streaming are unchanged. Never edit system trust, the cached
dependency, or the production binary. Requires POSIX, Zig, Node.js, and OpenSSL.
"""
import json
import hashlib
import os
from pathlib import Path
import queue
import re
import shutil
import signal
import subprocess
import tempfile
import threading
import time

REPO = Path(__file__).resolve().parents[1]


def run(args, **kwargs):
    timeout = kwargs.pop('timeout', 60)
    proc = subprocess.Popen(args, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                            text=True, start_new_session=True, **kwargs)
    try:
        stdout, stderr = proc.communicate(timeout=timeout)
    except subprocess.TimeoutExpired:
        terminate(proc)
        proc.communicate()
        raise
    if proc.returncode:
        raise RuntimeError(f'{args[0]} failed:\n{stdout}\n{stderr}')
    return subprocess.CompletedProcess(args, proc.returncode, stdout, stderr)


def certificates(root):
    run(['openssl', 'req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-days', '1',
         '-subj', '/CN=ACP integration CA', '-keyout', str(root/'ca.key'), '-out', str(root/'ca.pem')])
    run(['openssl', 'req', '-newkey', 'rsa:2048', '-nodes', '-subj', '/CN=localhost',
         '-keyout', str(root/'server.key'), '-out', str(root/'server.csr')])
    (root/'ext').write_text('subjectAltName=DNS:localhost\nextendedKeyUsage=serverAuth\n')
    run(['openssl', 'x509', '-req', '-in', str(root/'server.csr'), '-CA', str(root/'ca.pem'),
         '-CAkey', str(root/'ca.key'), '-CAcreateserial', '-days', '1', '-extfile', str(root/'ext'),
         '-out', str(root/'server.pem')])
    run(['openssl', 'req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-days', '1',
         '-subj', '/CN=localhost', '-addext', 'subjectAltName=DNS:localhost',
         '-keyout', str(root/'untrusted.key'), '-out', str(root/'untrusted.pem')])


def build(root):
    manifest = (REPO/'build.zig.zon').read_text()
    expected = re.search(r'\.http_zig\s*=\s*\.\{.*?\.hash\s*=\s*"([^"]+)"', manifest, re.S).group(1)
    packages = REPO/'zig-pkg'
    source = packages/expected
    assert source.is_dir(), 'Run zig build first to fetch the pinned dependencies'
    actual = run(['zig', 'fetch', str(source)], cwd=REPO).stdout.strip()
    assert actual == expected, 'Pinned HTTP/2 dependency contents were changed'
    isolated = root/'packages'
    isolated.mkdir()
    for package in packages.iterdir():
        if package.name == expected:
            shutil.copytree(package, isolated/package.name)
        else:
            (isolated/package.name).symlink_to(package.resolve(), target_is_directory=True)
    session = isolated/expected/'src/session.zig'
    original = session.read_text()
    seam = '        try self.ca.rescan(self.gpa, self.io, now);'
    assert original.count(seam) == 1, 'Review the test-only CA seam after dependency updates'
    injection = '\n        try self.ca.addCertsFromFilePathAbsolute(self.gpa, self.io, now, ' + json.dumps(str(root/'ca.pem')) + ');'
    session.write_text(original.replace(seam, seam + injection))
    print('Building isolated ACP binary; only trust-source injection differs', flush=True)
    # Each injected trust source must have its own build graph cache. Reusing
    # the repository cache can retain an earlier --system package directory.
    run(['zig', 'build', '--system', str(isolated), '--cache-dir', str(root/'cache'),
         '-p', str(root/'install')], cwd=REPO, timeout=240)
    return root/'install/bin/graff'


def terminate(proc):
    if proc is None:
        return
    if proc.poll() is not None:
        return
    try:
        os.killpg(proc.pid, signal.SIGTERM)
    except ProcessLookupError:
        pass
    try:
        proc.wait(timeout=3)
    except subprocess.TimeoutExpired:
        os.killpg(proc.pid, signal.SIGKILL)
        proc.wait(timeout=3)


def exercise(root, binary, name, cert, host, success):
    case = root/name
    case.mkdir()
    (case/'mcp.json').write_text('{"mcpServers":{}}')
    shim = case/'bin'
    shim.mkdir()
    (shim/'security').write_text('#!/bin/sh\nexit 44\n')
    (shim/'security').chmod(0o700)
    log = case/'server.jsonl'
    log.touch()
    server = worker = None
    with (case/'stderr').open('w') as stderr:
        try:
            server = subprocess.Popen(['node', str(REPO/'scripts/eval/http2-acp-mock.cjs'),
                                       str(root/f'{cert}.key'), str(root/f'{cert}.pem'), str(log)],
                                      stdout=subprocess.PIPE, stderr=stderr, text=True, start_new_session=True)
            ports = queue.Queue()
            threading.Thread(target=lambda: ports.put(server.stdout.readline()), daemon=True).start()
            port = int(ports.get(timeout=10))
            env = dict(HOME=str(case), PATH=str(shim)+':/usr/bin:/bin', TERM='dumb',
                       AI_GATEWAY_API_KEY='fixture', GRAFF_VERCEL_URL=f'https://{host}:{port}/v1/chat/completions',
                       GRAFF_MCP_CONFIG=str(case/'mcp.json'), GRAFF_HTTP2='1', GRAFF_NO_TELEMETRY='1',
                       GRAFF_FLEET='off', GRAFF_NO_ADOPT='1', GRAFF_NO_SMOLIFY='1', GRAFF_NO_CODEDB_GUARD='1')
            worker = subprocess.Popen([str(binary), 'acp', '--model', 'vercel', '--yolo'],
                                      cwd=case, env=env, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                      stderr=stderr, text=True, start_new_session=True)
            events = queue.Queue()

            def reader():
                try:
                    for line in worker.stdout:
                        events.put(json.loads(line))
                except Exception as error:
                    events.put(error)
                finally:
                    events.put(None)

            threading.Thread(target=reader, daemon=True).start()

            def send(method, params, identifier=None):
                message = dict(jsonrpc='2.0', method=method, params=params)
                if identifier is not None:
                    message['id'] = identifier
                worker.stdin.write(json.dumps(message)+'\n')
                worker.stdin.flush()

            def receive(identifier, timeout=30):
                deadline = time.monotonic()+timeout
                updates = []
                while True:
                    remaining = deadline-time.monotonic()
                    if remaining <= 0:
                        raise queue.Empty
                    event = events.get(timeout=remaining)
                    assert isinstance(event, dict), f'Invalid ACP output: {event}'
                    if event.get('id') == identifier:
                        return event, updates
                    assert 'id' not in event, f'Unexpected or duplicate ACP response: {event}'
                    updates.append(event)

            def call(method, params, identifier, timeout=30):
                send(method, params, identifier)
                return receive(identifier, timeout)

            def response_text(updates):
                return ''.join(e.get('params', {}).get('update', {}).get('content', {}).get('text', '')
                               for e in updates if e.get('params', {}).get('update', {}).get('sessionUpdate') == 'agent_message_chunk')

            def expected_text(number):
                return f'h2-response-{number}:' + '\n'.join(hashlib.sha256(str(i).encode()).hexdigest() for i in range(1500))

            init, _ = call('initialize', {'protocolVersion': 1}, 1)
            assert init['result']['protocolVersion'] == 1
            created, _ = call('session/new', {'cwd': str(case), 'mcpServers': []}, 2)
            sid = created['result']['sessionId']
            initial = created['result']['configOptions']
            assert len(initial) == 1 and initial[0]['category'] == 'thought_level', initial
            assert initial[0]['currentValue'] == 'medium', initial
            selected, _ = call('session/set_config_option', {
                'sessionId': sid, 'configId': 'thought_level', 'value': 'high'}, 8)
            options = selected['result']['configOptions']
            assert len(options) == 1 and options[0]['currentValue'] == 'high', selected
            assert not [r for r in (json.loads(line) for line in log.read_text().splitlines())
                        if r['event'] == 'request'], 'Effort selection made a network request'
            for number in range(1, 3 if success else 2):
                try:
                    result, updates = call('session/prompt', {'sessionId': sid, 'prompt': [
                        {'type': 'text', 'text': f'Reply with the fixture response {number}.'}]}, number+2, timeout=45 if success else 15)
                except queue.Empty:
                    assert not success, 'Trusted HTTP/2 prompt did not complete'
                    result, updates = {}, []
                records = [json.loads(line) for line in log.read_text().splitlines()]
                requests = [r for r in records if r['event'] == 'request']
                if not success:
                    assert not requests, f'{name}: invalid certificate accepted'
                    assert any(r['event'] == 'tls-error' for r in records), f'{name}: TLS rejection not observed'
                    assert result.get('result', {}).get('stopReason') != 'end_turn', result
                    break
                assert result.get('result', {}).get('stopReason') == 'end_turn', result
                text = response_text(updates)
                assert text == expected_text(number), (number, len(text))
                assert len(requests) == number, requests
                assert requests[0]['body']['reasoning']['effort'] == 'high', requests[0]['body'].get('reasoning')
                assert all(r['method'] == 'POST' and r['path'] == '/v1/chat/completions' for r in requests)
                assert all(r['alpn'] == 'h2' for r in records if r['event'] == 'session')
                if number == 1:
                    changed, updates = call('session/prompt', {'sessionId': sid, 'prompt': [
                        {'type': 'text', 'text': '/effort low'}]}, 9)
                    assert changed['result']['stopReason'] == 'end_turn', changed
                    changes = [e['params']['update'] for e in updates if e.get('method') == 'session/update'
                               and e['params']['update']['sessionUpdate'] == 'config_option_update']
                    assert len(changes) == 1 and changes[0]['configOptions'][0]['currentValue'] == 'low', changes
                    assert len([r for r in (json.loads(line) for line in log.read_text().splitlines())
                                if r['event'] == 'request']) == 1, 'Slash effort change made a network request'
                if number == 2:
                    assert requests[1]['body']['reasoning']['effort'] == 'low', requests[1]['body'].get('reasoning')
                    assert requests[0]['session'] == requests[1]['session'], 'Follow-up did not reuse HTTP/2 connection'
                    assert [r['stream'] for r in requests] == [1, 3], 'HTTP/2 stream IDs did not advance'
                    assert len(json.dumps(requests[1]['body'])) > 65535, 'Follow-up did not exercise upload flow control'
            if success:
                params = {'sessionId': sid, 'prompt': [{'type': 'text', 'text': 'Begin the stalled fixture response.'}]}
                send('session/prompt', params, 5)
                partial, deadline = [], time.monotonic()+10
                while response_text(partial) != 'before-cancel':
                    remaining = deadline-time.monotonic()
                    assert remaining > 0, 'Stalled HTTP/2 response did not begin streaming'
                    event = events.get(timeout=remaining)
                    assert isinstance(event, dict) and 'id' not in event, 'Prompt finished before cancellation'
                    partial.append(event)
                send('session/cancel', {'sessionId': sid})
                cancelled, updates = receive(5, timeout=10)
                assert cancelled.get('result', {}).get('stopReason') == 'cancelled', cancelled
                assert response_text(updates) == '', 'Cancelled turn emitted unexpected content'
                # Completion means the blocked read has been aborted, not just
                # that the UI received a cancellation acknowledgement.
                deadline = time.monotonic()+5
                while True:
                    records = [json.loads(line) for line in log.read_text().splitlines()]
                    stalled = next((r for r in records if r['event'] == 'stalled'), None)
                    if stalled and any(r['event'] == 'stream-closed' and r['session'] == stalled['session']
                                       and r['stream'] == stalled['stream'] for r in records):
                        break
                    assert time.monotonic() < deadline, 'Cancelled HTTP/2 stream remained open'
                    time.sleep(.02)
                result, updates = call('session/prompt', {'sessionId': sid, 'prompt': [
                    {'type': 'text', 'text': 'Continue after cancellation.'}]}, 6, timeout=30)
                assert result.get('result', {}).get('stopReason') == 'end_turn', result
                assert response_text(updates) == expected_text(4), 'Follow-up mixed or lost streamed text'
                records = [json.loads(line) for line in log.read_text().splitlines()]
                requests = [r for r in records if r['event'] == 'request']
                assert len(requests) == 4, 'Cancellation triggered extra provider requests'
                assert all(r['alpn'] == 'h2' for r in records if r['event'] == 'session')
                assert requests[3]['session'] != requests[2]['session'], 'Incomplete HTTP/2 connection was reused'
                print('PASS ACP TLS HTTP/2: stalled cancellation, stream closure, same-session recovery', flush=True)
                result, updates = call('session/prompt', {'sessionId': sid, 'prompt': [
                    {'type': 'text', 'text': 'Run the concurrent fixture child and continue the root.'}]}, 7, timeout=30)
                assert result.get('result', {}).get('stopReason') == 'end_turn', result
                assert 'root complete' in response_text(updates), 'Root response missing after child launch'
                records = [json.loads(line) for line in log.read_text().splitlines()]
                ready = next(r for r in records if r['event'] == 'concurrent-ready')
                assert sorted(ready['roles']) == [False, True], 'Root and child did not overlap'
                assert len(set(ready['sessions'])) == 2, 'Root and child shared a mutable HTTP/2 transport'
                assert len([r for r in records if r['event'] == 'request']) == 7, 'Concurrent requests retried unexpectedly'
                print('PASS ACP TLS HTTP/2: simultaneous root and background child streams', flush=True)
            print(f'PASS ACP TLS HTTP/2: {name}', flush=True)
        except Exception:
            stderr.flush()
            print('Server observations:', [(r.get('event'), r.get('request'), r.get('stream')) for r in
                                           (json.loads(line) for line in log.read_text().splitlines())])
            records = [json.loads(line) for line in log.read_text().splitlines()]
            for record in records:
                if record['event'] == 'request' and record['request'] >= 6:
                    print('Concurrent fixture tool results:', [m.get('content') for m in record['body'].get('messages', []) if m.get('role') == 'tool'][-2:])
            print((case/'stderr').read_text()[-5000:])
            raise
        finally:
            try:
                terminate(worker)
            finally:
                terminate(server)
                for proc in (worker, server):
                    if proc:
                        for pipe in (proc.stdin, proc.stdout):
                            if pipe:
                                pipe.close()


def main():
    with tempfile.TemporaryDirectory(prefix='graff-acp-http2-') as temp:
        root = Path(temp)
        certificates(root)
        binary = build(root)
        exercise(root, binary, 'trusted-streaming-followup', 'server', 'localhost', True)
        exercise(root, binary, 'untrusted-certificate', 'untrusted', 'localhost', False)
        exercise(root, binary, 'hostname-mismatch', 'server', '127.0.0.1', False)


if __name__ == '__main__':
    main()
