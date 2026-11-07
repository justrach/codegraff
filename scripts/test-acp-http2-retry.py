#!/usr/bin/env python3
"""Offline ACP regression for an ambiguous HTTP/2 failure after POST flush.

Builds with a verified copy of the pinned http-zig dependency. Only the local
CA trust source and controlled post-flush faults are injected into that copy.
The production harness and retry policy are used unchanged.
"""
import importlib.util
import json
from pathlib import Path
import queue
import re
import shutil
import subprocess
import tempfile
import threading
import time

REPO = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('acp_http2_fixture', REPO/'scripts/test-acp-http2.py')
fixture = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fixture)


def build(root):
    manifest = (REPO/'build.zig.zon').read_text()
    expected = re.search(r'\.http_zig\s*=\s*\.\{.*?\.hash\s*=\s*"([^"]+)"', manifest, re.S).group(1)
    source = REPO/'zig-pkg'/expected
    assert source.is_dir(), 'Run zig build first to fetch the pinned HTTP/2 dependency'
    actual = fixture.run(['zig', 'fetch', str(source)], cwd=REPO).stdout.strip()
    assert actual == expected, 'Pinned HTTP/2 dependency contents changed'
    packages = root/'packages'
    packages.mkdir()
    for package in (REPO/'zig-pkg').iterdir():
        if package.name == expected:
            shutil.copytree(package, packages/package.name)
        else:
            (packages/package.name).symlink_to(package.resolve(), target_is_directory=True)
    dep = packages/expected/'src'
    session = dep/'session.zig'
    contents = session.read_text()
    site = '        try self.ca.rescan(self.gpa, self.io, now);'
    assert contents.count(site) == 1, 'Review CA seam after dependency update'
    session.write_text(contents.replace(site, site + '\n        try self.ca.addCertsFromFilePathAbsolute(self.gpa, self.io, now, ' + json.dumps(str(root/'ca.pem')) + ');'))
    conn = dep/'conn.zig'
    contents = conn.read_text()
    start = contents.index('    pub fn startLines(self: *Conn, req: Request) !LineStream {')
    site = '        try self.sendBody(sid, req.body);'
    position = contents.index(site, start)
    assert contents.find(site, position + len(site), contents.index('\n    }', start)) == -1
    fault = '''
        // Test-only faults before the engine receives any response bytes:
        // recover once, exhaust a turn, then fail four times for cancellation.
        if (std.mem.eql(u8, req.authority, "localhost") and std.mem.eql(u8, req.method, "POST")) {
            const n = retry_fault_calls.fetchAdd(1, .acq_rel);
            if (n == 0 or (n >= 2 and n < 8) or (n >= 9 and n < 13)) {
                // Synchronize with the peer: an immediate close can race delivery
                // of the flushed POST, making the duplicate-body assertion flaky.
                var received = try self.readResponse(sid);
                received.deinit();
                return error.EndOfStream;
            }
        }
'''
    contents = contents[:position + len(site)] + fault + contents[position + len(site):]
    contents = contents.replace('const std = @import("std");', 'const std = @import("std");\nvar retry_fault_calls: std.atomic.Value(usize) = .init(0);', 1)
    conn.write_text(contents)
    fixture.run(['zig', 'build', '--system', str(packages), '--cache-dir', str(root/'cache'),
                 '-p', str(root/'install')], cwd=REPO, timeout=240)
    return root/'install/bin/graff'


def exercise(root, binary):
    case = root/'case'
    case.mkdir()
    (case/'mcp.json').write_text('{"mcpServers":{}}')
    shim = case/'bin'
    shim.mkdir()
    (shim/'security').write_text('#!/bin/sh\nexit 44\n')
    (shim/'security').chmod(0o700)
    log = root/'server.jsonl'
    log.touch()
    server = worker = None
    with (root/'server-stderr').open('w') as server_error, (root/'worker-stderr').open('w') as worker_error:
        try:
            server = subprocess.Popen(['node', str(REPO/'scripts/eval/http2-retry-mock.cjs'),
                                       str(root/'server.key'), str(root/'server.pem'), str(log)],
                                      stdout=subprocess.PIPE, stderr=server_error, text=True,
                                      start_new_session=True)
            ports = queue.Queue()
            threading.Thread(target=lambda: ports.put(server.stdout.readline()), daemon=True).start()
            port = int(ports.get(timeout=10))
            env = dict(HOME=str(case), PATH=str(shim)+':/usr/bin:/bin', TERM='dumb',
                       AI_GATEWAY_API_KEY='fixture', GRAFF_VERCEL_URL=f'https://localhost:{port}/v1/chat/completions',
                       GRAFF_MCP_CONFIG=str(case/'mcp.json'), GRAFF_HTTP2='1', GRAFF_NO_TELEMETRY='1',
                       GRAFF_FLEET='off', GRAFF_NO_ADOPT='1', GRAFF_NO_SMOLIFY='1', GRAFF_NO_CODEDB_GUARD='1')
            worker = subprocess.Popen([str(binary), 'acp', '--model', 'vercel', '--yolo'],
                                      cwd=case, env=env, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                      stderr=worker_error, text=True, start_new_session=True)
            events = queue.Queue()

            def read_events():
                for line in worker.stdout:
                    events.put(json.loads(line))
                events.put(None)

            threading.Thread(target=read_events, daemon=True).start()

            def call(method, params, identifier, timeout=35):
                worker.stdin.write(json.dumps({'jsonrpc':'2.0', 'id':identifier, 'method':method, 'params':params})+'\n')
                worker.stdin.flush()
                deadline = time.monotonic() + timeout
                updates = []
                while True:
                    event = events.get(timeout=max(0, deadline-time.monotonic()))
                    assert isinstance(event, dict), f'ACP exited before response {identifier}'
                    if event.get('id') == identifier:
                        return event, updates
                    assert 'id' not in event, f'Unexpected ACP response: {event}'
                    updates.append(event)

            def chunks(updates):
                return [e.get('params', {}).get('update', {}).get('content', {}).get('text', '')
                        for e in updates if e.get('params', {}).get('update', {}).get('sessionUpdate') == 'agent_message_chunk']

            init, _ = call('initialize', {'protocolVersion':1}, 1)
            assert init['result']['protocolVersion'] == 1
            created, _ = call('session/new', {'cwd':str(case), 'mcpServers':[]}, 2)
            sid = created['result']['sessionId']
            result, updates = call('session/prompt', {'sessionId':sid, 'prompt':[{'type':'text', 'text':'Say OK.'}]}, 3)
            assert result.get('result', {}).get('stopReason') == 'end_turn', result
            reply_chunks = chunks(updates)
            # #625: retry housekeeping is chrome, never answer/thought content.
            # ACP has no retry-status channel; do not counterfeit a message.
            assert reply_chunks == ['OK'], reply_chunks
            assert not any('network error:' in json.dumps(event) or 'retrying in' in json.dumps(event)
                           for event in updates), updates
            rows = [json.loads(line) for line in log.read_text().splitlines()]
            posts = [row for row in rows if row['event'] == 'post']
            assert len(posts) == 2, posts
            assert not any(row['protocol'] == 'h1' for row in posts), posts
            assert all(row['protocol'] == 'h2' and row['method'] == 'POST' and row['path'] == '/v1/chat/completions' for row in posts), posts
            assert posts[0]['sha256'] == posts[1]['sha256'] and posts[0]['bytes'] > 0, posts
            assert all(row['alpn'] == 'h2' for row in rows if row['event'] == 'session'), rows
            cost, cost_updates = call('session/prompt', {'sessionId':sid, 'prompt':[{'type':'text', 'text':'/cost'}]}, 4)
            assert cost.get('result', {}).get('stopReason') == 'end_turn', cost
            receipt = ''.join(chunks(cost_updates))
            assert '1 failed request attempt(s) without usage' in receipt, receipt
            assert 'known subtotal: 1 api call(s) · 10 in' in receipt, receipt
            assert '+ 2 out tokens' in receipt, receipt
            assert posts[1]['atMs'] - posts[0]['atMs'] >= 200, 'Second POST bypassed the 250ms request-level retry'
            after_cost = [json.loads(line) for line in log.read_text().splitlines()]
            assert len([row for row in after_cost if row['event'] == 'post']) == 2, '/cost caused a model POST'
            failed, failed_updates = call('session/prompt', {'sessionId':sid, 'prompt':[{'type':'text', 'text':'Exercise the exhausted transport fixture.'}]}, 5)
            assert failed.get('error', {}).get('code') == -32603, failed
            assert 'EndOfStream (gave up after 6 attempts)' in failed['error']['message'], failed
            assert chunks(failed_updates) == [], failed_updates
            assert not any('network error:' in json.dumps(event) or 'retrying in' in json.dumps(event)
                           for event in failed_updates), failed_updates
            failed_posts = [json.loads(line) for line in log.read_text().splitlines()
                            if json.loads(line)['event'] == 'post'][2:]
            assert len(failed_posts) == 6, failed_posts
            assert len({row['sha256'] for row in failed_posts}) == 1, failed_posts
            assert all(row['protocol'] == 'h2' for row in failed_posts), failed_posts
            resumed, resumed_updates = call('session/prompt', {'sessionId':sid, 'prompt':[{'type':'text', 'text':'Try again explicitly.'}]}, 6)
            assert resumed.get('result', {}).get('stopReason') == 'end_turn', resumed
            assert chunks(resumed_updates) == ['OK'], resumed_updates
            for mode in ('json', 'oneshot'):
                work = case/mode
                work.mkdir()
                before = len([row for row in map(json.loads, log.read_text().splitlines())
                              if row['event'] == 'post'])
                args = [str(binary), '--model', 'vercel', '--yolo']
                stdin = ''
                if mode == 'json':
                    args += ['--json']
                    stdin = json.dumps({'type':'user', 'text':'Say OK.'}) + '\n'
                else:
                    args += ['-p', 'Say OK.']
                run = subprocess.Popen(args, cwd=work, env=env, stdin=subprocess.PIPE,
                                       stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                       text=True, start_new_session=True)
                try:
                    stdout, stderr = run.communicate(stdin, timeout=45)
                    assert run.returncode == 0, (mode, stderr)
                finally:
                    fixture.terminate(run)
                assert 'network error:' not in stdout and 'retrying in' not in stdout, stdout
                assert '· retry' not in stdout, stdout
                if mode == 'json':
                    wire = [json.loads(line) for line in stdout.splitlines()]
                    turns = [event for event in wire if event.get('type') == 'turn']
                    assert len(turns) == 1 and turns[0]['text'] == 'OK', turns
                    text = ''.join(event.get('text', '') for event in wire if event.get('type') == 'text')
                    assert text == 'OK', text
                    sequence = [event['seq'] for event in wire]
                    assert sequence == list(range(sequence[0], sequence[0] + len(sequence))), sequence
                else:
                    assert stdout.strip() == 'OK', stdout
                posts = [row for row in map(json.loads, log.read_text().splitlines())
                         if row['event'] == 'post'][before:]
                assert len(posts) == 2 and posts[0]['sha256'] == posts[1]['sha256'], (mode, posts)
                assert all(row['protocol'] == 'h2' for row in posts), (mode, posts)
                trace = [row for path in (work/'.graff/traces').glob('*.jsonl')
                         for row in map(json.loads, path.read_text().splitlines())]
                assert any(row.get('ev') == 'retry' for row in trace), (mode, 'retry breadcrumb missing')
                print(f'PASS {mode} retry chrome: two matching POSTs, clean answer, raw retry trace retained')
            def retries():
                count = 0
                for path in (case/'.graff/traces').glob('*.jsonl'):
                    for line in path.read_text().splitlines(keepends=True):
                        # A trace append may be in flight; only parse full rows.
                        if line.endswith('\n') and json.loads(line).get('ev') == 'retry':
                            count += 1
                return count

            before = len([row for row in map(json.loads, log.read_text().splitlines())
                          if row['event'] == 'post'])
            retry_count = retries()
            worker.stdin.write(json.dumps({'jsonrpc':'2.0', 'id':7, 'method':'session/prompt',
                                           'params':{'sessionId':sid, 'prompt':[{'type':'text', 'text':'Exercise the cancelled transport fixture.'}]}}) + '\n')
            worker.stdin.flush()
            deadline = time.monotonic() + 15
            # Wait for the fourth retry breadcrumb: its two-second backoff is
            # now in progress, rather than guessing when a request failed.
            while retries() < retry_count + 4:
                assert time.monotonic() < deadline, 'Transport backoff was not reached'
                time.sleep(.01)
            started = time.monotonic()
            worker.stdin.write(json.dumps({'jsonrpc':'2.0', 'method':'session/cancel',
                                           'params':{'sessionId':sid}}) + '\n')
            worker.stdin.flush()
            cancelled_updates = []
            while True:
                event = events.get(timeout=max(.01, started + 5 - time.monotonic()))
                assert isinstance(event, dict), 'ACP exited during retry cancellation'
                if event.get('id') == 7:
                    assert event.get('result', {}).get('stopReason') == 'cancelled', event
                    break
                cancelled_updates.append(event)
            assert time.monotonic() - started < 2, 'Cancellation waited out the retry backoff'
            assert chunks(cancelled_updates) == [], cancelled_updates
            cancelled_posts = [row for row in map(json.loads, log.read_text().splitlines())
                               if row['event'] == 'post'][before:]
            assert len(cancelled_posts) == 4, cancelled_posts
            assert len({row['sha256'] for row in cancelled_posts}) == 1, cancelled_posts
            after_cancel, after_cancel_updates = call('session/prompt', {'sessionId':sid, 'prompt':[{'type':'text', 'text':'Try once more explicitly.'}]}, 8)
            assert after_cancel.get('result', {}).get('stopReason') == 'end_turn', after_cancel
            assert chunks(after_cancel_updates) == ['OK'], after_cancel_updates
            print('PASS ACP retry cancellation: interrupts backoff, no extra POST or answer, same session remains usable')
            print('PASS ACP HTTP/2 retry chrome: recovery, six-attempt exhaustion, explicit retry; no retry text in answers')
        finally:
            fixture.terminate(worker)
            fixture.terminate(server)


if __name__ == '__main__':
    with tempfile.TemporaryDirectory(prefix='acp-http2-retry-') as name:
        root = Path(name)
        fixture.certificates(root)
        exercise(root, build(root))
