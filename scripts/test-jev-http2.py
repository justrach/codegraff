#!/usr/bin/env python3
"""Offline loopback check of the bounded HTTPS cancellation path."""
import importlib.util
import json
from pathlib import Path
import queue
import subprocess
import tempfile
import threading
import time

REPO = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('h2_fixture', REPO/'scripts/test-acp-http2.py')
fixture = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fixture)


def exercise(root):
    fixture.certificates(root)
    fixture.build(root)  # verifies the exact pinned package and injects only the local CA
    log = root/'server.jsonl'
    log.touch()
    with (root/'server-stderr').open('w') as stderr:
        server = subprocess.Popen(['node', str(REPO/'scripts/eval/jev-http2-stall.cjs'),
                                   str(root/'server.key'), str(root/'server.pem'), str(log)],
                                  stdout=subprocess.PIPE, stderr=stderr, text=True, start_new_session=True)
        try:
            ports = queue.Queue()
            threading.Thread(target=lambda: ports.put(server.stdout.readline()), daemon=True).start()
            port = int(ports.get(timeout=10))
            env = dict(__import__('os').environ,
                       GRAFF_JEV_HTTP2_STALL_URL=f'https://localhost:{port}/v1/systemone',
                       GRAFF_JEV_HTTP2_DROP_URL=f'https://localhost:{port}/drop')
            start = time.monotonic()
            result = fixture.run(['zig', 'build', 'test', '--system', str(root/'packages'),
                                  '--cache-dir', str(root/'test-cache'),
                                  '-Dtest-filter=loopback HTTP', '--summary', 'all'],
                                 cwd=REPO, env=env, timeout=240)
            elapsed = time.monotonic() - start
            assert '1 skipped' not in result.stderr, result.stderr
            deadline = time.monotonic() + 5
            while time.monotonic() < deadline:
                rows = [json.loads(line) for line in log.read_text().splitlines()]
                if any(row['event'] == 'closed' for row in rows):
                    break
                time.sleep(.02)
            assert any(row['event'] == 'session' and row['alpn'] == 'h2' for row in rows), rows
            requests = [row for row in rows if row['event'] == 'request']
            assert len(requests) == 2, rows
            assert {row['path'] for row in requests} == {'/v1/systemone', '/drop'}, requests
            assert all(row['method'] == 'POST' and row['auth'] == 'Bearer fixture' and row['body'] == '{}' for row in requests), requests
            assert len([row for row in rows if row['event'] == 'dropped']) == 1, rows
            assert any(row['event'] == 'stalled' for row in rows), rows
            assert any(row['event'] == 'closed' for row in rows), rows
            print(f'PASS Jev HTTPS: stalled h2 canceled/closed, ambiguous drop had one POST; test command {elapsed:.1f}s', flush=True)
        finally:
            fixture.terminate(server)


if __name__ == '__main__':
    with tempfile.TemporaryDirectory(prefix='jev-http2-') as name:
        exercise(Path(name))
