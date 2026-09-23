#!/usr/bin/env python3
"""Native async calls overlap model output over real TLS/ALPN HTTP/2."""
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile

REPO = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('acp_h2', REPO/'scripts/test-acp-http2.py')
fixture = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fixture)


def exercise(root, binary, mode):
    case = root/mode
    case.mkdir(mode=0o700)
    (case/'mcp.json').write_text('{"mcpServers":{}}')
    (case/'auth.json').write_text(json.dumps({'auth_mode': 'chatgpt', 'tokens': {
        'access_token': 'local-fixture', 'refresh_token': '', 'account_id': 'fixture'}}))
    (case/'.simple-harness-model').write_text('codex\ngpt-6-sol\n')
    shim = case/'bin'
    shim.mkdir()
    (shim/'security').write_text('#!/bin/sh\nexit 44\n')
    (shim/'security').chmod(0o700)
    log = case/'server.jsonl'
    log.touch()
    server = None
    with (case/'server-stderr').open('w') as stderr:
        try:
            server = subprocess.Popen(['node', str(REPO/'scripts/eval/http2-async-mock.cjs'),
                str(root/'server.key'), str(root/'server.pem'), str(log), mode],
                stdout=subprocess.PIPE, stderr=stderr, text=True, start_new_session=True)
            port = int(server.stdout.readline())
            env = dict(HOME=str(case), CODEX_HOME=str(case), PATH=str(shim)+':/usr/bin:/bin',
                TERM='dumb', GRAFF_CODEX_URL=f'https://localhost:{port}/responses', GRAFF_CODEX_WS='off',
                GRAFF_MCP_CONFIG=str(case/'mcp.json'), GRAFF_HTTP2='1', GRAFF_ASYNC_TOOLS='0' if mode == 'off' else '1',
                GRAFF_NO_NATIVE_FOLD='1', GRAFF_NO_CODEDB_GUARD='1', GRAFF_NO_TELEMETRY='1',
                GRAFF_FLEET='off', GRAFF_NO_ADOPT='1', GRAFF_NO_SMOLIFY='1', GRAFF_BEHAVIOR_UPLOAD='off', NO_COLOR='1')
            run = subprocess.run([str(binary), '--old', '--no-lean', '--max-model-calls', '3',
                '-p', 'Run the fixture lookup and report its result.'], cwd=case, env=env,
                capture_output=True, text=True, timeout=25)
            (case/'stdout').write_text(run.stdout)
            (case/'stderr').write_text(run.stderr)
            rows = [json.loads(line) for line in log.read_text().splitlines()]
            by = lambda event: [r for r in rows if r['event'] == event]
            assert by('session') and all(r['alpn'] == 'h2' for r in by('session')), rows
            requests = by('request')
            definition = next(t for t in requests[0]['body']['tools'] if t.get('name') == 'webfetch')
            assert bool(definition.get('async')) == (mode != 'off'), definition
            starts = by('lookup-start')
            assert len(starts) == 1, (mode, rows, run.stderr)
            if mode == 'failed':
                assert run.returncode != 0 and len(requests) == 1, (rows, run.stderr)
                assert starts[0]['ms'] < by('response-failed')[0]['ms'], rows
            else:
                assert run.returncode == 0 and 'ASYNC_FIXTURE_DONE' in run.stdout, run.stderr
                assert len(requests) == 2 and by('delivered')[0]['correct'], rows
                terminal = by('response-completed')[0]['ms']
                if mode == 'off':
                    assert starts[0]['ms'] >= terminal, rows
                else:
                    assert starts[0]['ms'] < terminal, rows
                    assert by('independent-prose')[0]['ms'] < by('lookup-end')[0]['ms'], rows
            return {'mode': mode, 'exit': run.returncode, 'requests': len(requests),
                    'lookup_calls': len(starts), 'alpn': 'h2',
                    'lookup_start_ms': round(starts[0]['ms'] - requests[0]['ms'], 2),
                    'continuation_ms': round(requests[1]['ms'] - requests[0]['ms'], 2) if len(requests) > 1 else None}
        finally:
            fixture.terminate(server)


def main():
    root = Path(tempfile.mkdtemp(prefix='graff-async-h2-'))
    os.chmod(root, 0o700)
    print(f'Private evidence: {root}', flush=True)
    fixture.certificates(root)
    binary = fixture.build(root)
    results = []
    for mode in ('on', 'off', 'duplicate', 'failed'):
        result = exercise(root, binary, mode)
        results.append(result)
        print(json.dumps(result), flush=True)
    (root/'results.json').write_text(json.dumps(results, indent=2))
    print('PASS native async calls over TLS HTTP/2', flush=True)


if __name__ == '__main__':
    main()
