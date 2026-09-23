#!/usr/bin/env python3
"""Offline Chat completion deadlines through real TLS/ALPN HTTP/2.

Reuses the ACP fixture's isolated additive CA seam; no production trust or
cached dependency changes. A server that forbids HTTP/1 proves this exercises
agent_stream_h2, including a delayed usage trailer and a silent open stream.
"""
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile
import time

REPO = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('acp_h2', REPO/'scripts/test-acp-http2.py')
fixture = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fixture)


def exercise(root, binary, mode):
    case = root/mode
    case.mkdir(mode=0o700)
    (case/'mcp.json').write_text('{"mcpServers":{}}')
    shim = case/'bin'
    shim.mkdir()
    (shim/'security').write_text('#!/bin/sh\nexit 44\n')
    (shim/'security').chmod(0o700)
    log = case/'server.jsonl'
    log.touch()
    server = None
    with (case/'server-stderr').open('w') as stderr:
        try:
            server = subprocess.Popen(['node', str(REPO/'scripts/eval/http2-acp-mock.cjs'),
                                       str(root/'server.key'), str(root/'server.pem'), str(log), mode],
                                      stdout=subprocess.PIPE, stderr=stderr, text=True, start_new_session=True)
            port = int(server.stdout.readline())
            env = dict(HOME=str(case), PATH=str(shim)+':/usr/bin:/bin', TERM='dumb',
                       AI_GATEWAY_API_KEY='fixture', GRAFF_VERCEL_URL=f'https://localhost:{port}/v1/chat/completions',
                       GRAFF_MCP_CONFIG=str(case/'mcp.json'), GRAFF_HTTP2='1', GRAFF_STREAM_STALL_SECS='1',
                       GRAFF_NO_TELEMETRY='1', GRAFF_FLEET='off', GRAFF_NO_ADOPT='1',
                       GRAFF_NO_SMOLIFY='1', GRAFF_BEHAVIOR_UPLOAD='off', NO_COLOR='1')
            start = time.monotonic()
            run = subprocess.run([str(binary), '-p', '--model', 'vercel', '--no-local-tools', 'Reply OK'],
                                 cwd=case, env=env, capture_output=True, text=True, timeout=20)
            elapsed = time.monotonic()-start
            (case/'stdout').write_text(run.stdout)
            (case/'stderr').write_text(run.stderr)
            rows = [json.loads(line) for line in log.read_text().splitlines()]
            sessions = [r for r in rows if r['event'] == 'session']
            requests = [r for r in rows if r['event'] == 'request']
            assert sessions and all(r['alpn'] == 'h2' for r in sessions), rows
            expected = 3 if mode in ('quiet-unterminated', 'quiet-empty') else 1
            assert len(requests) == expected, (mode, len(requests), run.stderr)
            if mode == 'quiet-unterminated':
                assert run.returncode != 0 and 'StreamStalled' in run.stderr, run.stderr
            else:
                assert run.returncode == 0, run.stderr
                if mode != 'quiet-empty':
                    assert run.stdout.strip() == 'OK', run.stdout
                if mode in ('done', 'quiet-usage'):
                    assert '20 in (0 cached, 0 cache writes) + 2 out tokens' in run.stderr, run.stderr
                    assert 'missing usage' not in run.stderr, run.stderr
                else:
                    assert f'totals incomplete: {expected} call(s) missing usage' in run.stderr, run.stderr
                traces = [json.loads(line) for path in case.glob('.graff/traces/*.jsonl')
                          for line in path.read_text().splitlines()]
                assert not any(r.get('ev') == 'stream_retry' for r in traces), traces
                if mode == 'quiet-empty':
                    # The model loop independently retries semantically empty answers.
                    assert 'empty completion' in run.stderr, run.stderr
            return dict(mode=mode, requests=len(requests), exit=run.returncode,
                        elapsed_s=round(elapsed, 3), alpn='h2')
        finally:
            fixture.terminate(server)


def main():
    root = Path(tempfile.mkdtemp(prefix='graff-chat-h2-'))
    os.chmod(root, 0o700)
    print(f'Private evidence: {root}', flush=True)
    fixture.certificates(root)
    binary = fixture.build(root)
    results = []
    for mode in ('done', 'quiet-usage', 'quiet-no-usage', 'quiet-empty', 'quiet-unterminated'):
        result = exercise(root, binary, mode)
        results.append(result)
        print(json.dumps(result), flush=True)
    (root/'results.json').write_text(json.dumps(results, indent=2))
    print('PASS Chat completion deadlines over TLS HTTP/2', flush=True)


if __name__ == '__main__':
    main()
