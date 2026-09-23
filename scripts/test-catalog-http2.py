#!/usr/bin/env python3
"""Offline authenticated catalog GET over TLS/ALPN h2 with a pinned test CA."""
import importlib.util
import json
import os
from pathlib import Path
import queue
import subprocess
import tempfile
import threading

REPO = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('h2_fixture', REPO/'scripts/test-acp-http2.py')
fixture = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fixture)


def exercise(root):
    fixture.certificates(root)
    fixture.build(root)  # verifies the pin and injects only the fixture CA
    log = root/'server.jsonl'
    log.touch()
    with (root/'server-stderr').open('w') as stderr:
        server = subprocess.Popen(['node', str(REPO/'scripts/eval/catalog-http2.cjs'), str(root/'server.key'), str(root/'server.pem'), str(log)],
                                  stdout=subprocess.PIPE, stderr=stderr, text=True, start_new_session=True)
        try:
            ports = queue.Queue()
            threading.Thread(target=lambda: ports.put(server.stdout.readline()), daemon=True).start()
            h2_port, h1_port = map(int, ports.get(timeout=10).split())
            env = dict(os.environ, GRAFF_CATALOG_HTTP2_URL=f'https://localhost:{h2_port}',
                       GRAFF_CATALOG_H1_URL=f'https://localhost:{h1_port}',
                       GRAFF_CATALOG_CA_CERT=str(root/'ca.pem'))
            try:
                result = fixture.run(['zig', 'build', 'test', '--system', str(root/'packages'), '--cache-dir', str(root/'test-cache'),
                                      '-Dtest-filter=loopback catalog HTTP2', '--summary', 'all'], cwd=REPO, env=env, timeout=240)
            except RuntimeError:
                print('server log:', log.read_text(), flush=True)
                print('server stderr:', (root/'server-stderr').read_text(), flush=True)
                raise
            assert '1 skipped' not in result.stderr, result.stderr
            rows = [json.loads(line) for line in log.read_text().splitlines()]
            sessions = [row for row in rows if row['event'] == 'session']
            requests = [row for row in rows if row['event'] == 'request']
            h1_requests = [row for row in rows if row['event'] == 'h1_request']
            assert sessions and all(row['alpn'] == 'h2' for row in sessions), rows
            assert [row['path'] for row in requests] == ['/v1/models?limit=1000', '/v1/models?limit=1000&after_id=first', '/redirect', '/v1/models?limit=1000', '/cross-redirect', '/cross-loop', '/cross-loop', '/deny', '/oversize', '/large-valid', '/stall', '/v1/models?limit=1000'], rows
            assert all(row['method'] == 'GET' and row['key'] == 'fixture-key' and row['version'] == '2023-06-01' and row['accept'] == 'application/json' for row in requests[:6]), rows
            assert all(row.get('key') is None and row.get('version') is None and row['accept'] == 'application/json' for row in (requests[6], requests[-1])), rows
            assert all(row['key'] == 'fixture-key' and row['version'] == '2023-06-01' for row in requests[7:-1]), rows
            assert requests[0]['session'] == requests[1]['session'] and [row['stream'] for row in requests[:2]] == [1, 3], rows
            assert [row['path'] for row in h1_requests] == ['/v1/models?limit=1000', '/cross-loop', '/cross-loop', '/v1/models?limit=1000', '/redirect', '/v1/models?limit=1000', '/cross-redirect', '/deny-stall', '/oversize'], rows
            assert all(row['method'] == 'GET' and row['key'] == 'fixture-key' and row['version'] == '2023-06-01' for row in h1_requests[3:]), rows
            assert all(row.get('key') is None and row.get('version') is None and row['accept'] == 'application/json' for row in h1_requests[:3]), rows
            print('PASS catalog HTTPS: auth, cursor, redirects, pooled h2, TLS h1 fallback, status-first errors, large page, deadline', flush=True)
        finally:
            fixture.terminate(server)


if __name__ == '__main__':
    with tempfile.TemporaryDirectory(prefix='catalog-http2-') as name:
        exercise(Path(name))
