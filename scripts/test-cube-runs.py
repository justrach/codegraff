#!/usr/bin/env python3
"""Short-lived cloud agents against a mock gateway (no network, no spend).

- `graff cube spawn` never puts the account key on the box: the launch token
  arrives as an uploaded run file that is then made 0600; the agent starts
  with no key in its command line
- a failed run creation deletes the sandbox it just made
- `graff cube runs` / `graff cube kill <run>|--all` map to /v1/runs
- `graff remote-control` on a run token renews it and exits when the run is
  revoked, authenticating with the run token, not an account key
"""
import base64, json, os, shutil, subprocess, sys, tempfile, threading, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

OWNER = 'cg_sk_owner_secret_value_0123456789'
TOKEN = 'cg_lt_' + 'ab' * 24


class Gateway:
    def __init__(self, fail_run=False, renew_script=('ok', 'revoked')):
        self.fail_run = fail_run
        self.renew_script = list(renew_script)
        self.execs, self.uploads, self.calls, self.auth = [], [], [], []
        self.deleted_sandboxes, self.run_body = [], None
        gw = self

        class H(BaseHTTPRequestHandler):
            def log_message(self, *a):
                pass

            def reply(self, code, obj):
                data = json.dumps(obj).encode()
                self.send_response(code)
                self.send_header('Content-Type', 'application/json')
                self.send_header('Content-Length', str(len(data)))
                self.end_headers()
                self.wfile.write(data)

            def body(self):
                n = int(self.headers.get('Content-Length') or 0)
                raw = self.rfile.read(n) if n else b''
                return json.loads(raw) if raw else {}

            def handle_any(self, method):
                path = self.path
                gw.calls.append((method, path))
                gw.auth.append((path, self.headers.get('Authorization', '')))
                b = self.body() if method in ('POST', 'DELETE') else {}
                base = f'http://127.0.0.1:{gw.port}'
                if method == 'POST' and path == '/v1/sandboxes':
                    return self.reply(200, {'id': 'sb1', 'state': 'started'})
                if method == 'GET' and path == '/v1/sandboxes/sb1':
                    return self.reply(200, {'id': 'sb1', 'state': 'started'})
                if method == 'DELETE' and path == '/v1/sandboxes/sb1':
                    gw.deleted_sandboxes.append('sb1')
                    return self.reply(200, {})
                if method == 'POST' and path == '/v1/sandboxes/sb1/exec':
                    cmd = b.get('command', '')
                    gw.execs.append(cmd)
                    out = ''
                    if '--version' in cmd:
                        out = 'graff 0.0.302.6\n'
                    elif 'echo $HOME' in cmd:
                        out = '/home/daytona\n'
                    elif 'remote-control.log' in cmd and 'tail' in cmd:
                        out = 'graff remote-control · agent (sb1) · device 0123456789abcdef'
                    return self.reply(200, {'exitCode': 0, 'result': out, 'execId': 'e1'})
                if method == 'POST' and path == '/v1/sandboxes/sb1/upload':
                    gw.uploads.append((b['path'], base64.b64decode(b['contentBase64']).decode()))
                    return self.reply(200, {})
                if method == 'POST' and path == '/v1/runs':
                    gw.run_body = b
                    if gw.fail_run:
                        return self.reply(402, {'error': {'message': 'insufficient credits', 'type': 'insufficient_credits'}})
                    run_file = json.dumps({'token': TOKEN, 'run_id': 'r1', 'expires_at': int(time.time()) + 1800,
                                           'max_expires_at': int(time.time()) + 21600, 'renew_url': f'{base}/v1/runs/r1/renew'})
                    return self.reply(201, {'run_id': 'r1', 'token': TOKEN, 'run_file': run_file, 'expires_at': int(time.time()) + 1800})
                if method == 'GET' and path == '/v1/runs':
                    return self.reply(200, {'runs': [{'run_id': 'r1', 'state': 'active', 'expires_at': int(time.time()) + 600,
                                                      'labels': {'name': 'mimo', 'model': 'codegraff/mimo-v2.6-pro'}, 'sandbox_state': 'started'}]})
                if method == 'DELETE' and path.startswith('/v1/runs/r1'):
                    return self.reply(200, {'run_id': 'r1', 'revoked_at': 1, 'sandbox': 'deleted', 'devices_dropped': 1})
                if method == 'DELETE' and path.startswith('/v1/runs'):
                    return self.reply(200, {'killed': [{'run_id': 'r1', 'sandbox': 'deleted'}, {'run_id': 'r2', 'sandbox': 'stopped'}]})
                if method == 'POST' and path == '/v1/runs/r1/renew':
                    step = gw.renew_script.pop(0) if gw.renew_script else 'revoked'
                    if step == 'ok':
                        return self.reply(200, {'run_id': 'r1', 'expires_at': int(time.time()) + 4})
                    return self.reply(409, {'error': {'type': 'run_revoked', 'message': 'run revoked'}})
                if method == 'POST' and path.startswith('/v1/remote/agents/') and path.endswith('/register'):
                    return self.reply(200, {})
                if method == 'POST' and path.startswith('/v1/remote/agents/') and path.endswith('/poll'):
                    time.sleep(0.5)
                    return self.reply(200, {'commands': []})
                return self.reply(404, {'error': {'message': f'no route {method} {path}'}})

            def do_GET(self):
                self.handle_any('GET')

            def do_POST(self):
                self.handle_any('POST')

            def do_DELETE(self):
                self.handle_any('DELETE')

        self.server = ThreadingHTTPServer(('127.0.0.1', 0), H)
        self.port = self.server.server_address[1]
        threading.Thread(target=self.server.serve_forever, daemon=True).start()

    def stop(self):
        self.server.shutdown()


def graff(binary, home, gw, *args, key=OWNER, timeout=60):
    env = {'HOME': str(home), 'PATH': os.environ.get('PATH', '/usr/bin:/bin'), 'GRAFF_NO_TELEMETRY': '1',
           'GRAFF_GATEWAY_BASE': f'http://127.0.0.1:{gw.port}', 'GRAFF_REMOTE_BASE': f'http://127.0.0.1:{gw.port}', 'TERM': 'dumb'}
    if key:
        env['CODEGRAFF_API_KEY'] = key
    return subprocess.run([binary, *args], env=env, capture_output=True, text=True, timeout=timeout)


def main():
    if os.name != 'posix':
        print('cube runs mock-gateway test: POSIX only')
        return
    binary = str(Path(sys.argv[1] if len(sys.argv) > 1 else 'zig-out/bin/graff').resolve())
    home = Path(tempfile.mkdtemp(prefix='cube-runs-'))
    try:
        # spawn: the account key never reaches the box
        gw = Gateway()
        r = graff(binary, home, gw, 'cube', 'spawn', '--model', 'codegraff/mimo-v2.6-pro', '--task', 'fix-tests', '--ttl', '20')
        gw.stop()
        assert r.returncode == 0, r.stdout + r.stderr
        assert 'run r1' in r.stdout, r.stdout
        body = gw.run_body
        assert body['sandbox_id'] == 'sb1' and body['scopes'] == ['inference', 'remote-device'], body
        assert body['ttl_seconds'] == 1200 and body['on_end'] == 'delete', body
        assert body['labels']['model'] == 'codegraff/mimo-v2.6-pro' and body['labels']['task'] == 'fix-tests', body
        assert all(OWNER not in c and 'cg_sk_' not in c and 'cg_lt_' not in c for c in gw.execs), gw.execs
        assert len(gw.uploads) == 1 and gw.uploads[0][0] == '/home/daytona/.codegraff/run.json', gw.uploads
        assert json.loads(gw.uploads[0][1])['token'] == TOKEN
        upload_at = next(i for i, c in enumerate(gw.execs) if 'chmod 600' in c)
        start = next(c for c in gw.execs if 'remote-control' in c and 'tail' not in c)
        assert gw.execs.index(start) > upload_at, 'agent started before the run file was locked down'
        assert "--model 'codegraff/mimo-v2.6-pro'" in start and '--yolo' in start, start
        print('PASS cube spawn: token delivered as a 0600 file, never in a command', flush=True)

        # a failed run creation cleans up its sandbox
        gw = Gateway(fail_run=True)
        r = graff(binary, home, gw, 'cube', 'spawn', '--model', 'codegraff/deepseek-v4-pro')
        gw.stop()
        assert r.returncode != 0 and gw.deleted_sandboxes == ['sb1'], (r.returncode, gw.deleted_sandboxes, r.stdout)
        print('PASS cube spawn: failed run deletes its sandbox', flush=True)

        # unsafe names never reach the box shell
        gw = Gateway()
        r = graff(binary, home, gw, 'cube', 'spawn', '--name', "x';touch /tmp/pwned;'")
        gw.stop()
        assert r.returncode != 0 and not gw.calls, (r.returncode, gw.calls)
        print('PASS cube spawn: shell-unsafe names rejected before any call', flush=True)

        # runs / kill
        gw = Gateway()
        r = graff(binary, home, gw, 'cube', 'runs')
        assert r.returncode == 0 and 'r1' in r.stdout and 'mimo-v2.6-pro' in r.stdout, r.stdout + r.stderr
        r = graff(binary, home, gw, 'cube', 'kill', 'r1')
        assert r.returncode == 0 and 'run r1 killed' in r.stdout and ('DELETE', '/v1/runs/r1') in gw.calls, (r.stdout, gw.calls)
        r = graff(binary, home, gw, 'cube', 'kill', '--all', '--sandbox', 'stop')
        assert r.returncode == 0 and 'run r2 killed' in r.stdout and ('DELETE', '/v1/runs?sandbox=stop') in gw.calls, (r.stdout, gw.calls)
        gw.stop()
        print('PASS cube runs/kill map to /v1/runs', flush=True)

        # remote-control on a run token: renews, then exits when revoked
        gw = Gateway(renew_script=('ok', 'revoked'))
        box = Path(tempfile.mkdtemp(prefix='cube-box-'))
        (box / '.codegraff').mkdir()
        (box / '.codegraff' / 'run.json').write_text(json.dumps({
            'token': TOKEN, 'run_id': 'r1', 'expires_at': int(time.time()) + 4,
            'max_expires_at': int(time.time()) + 600, 'renew_url': f'http://127.0.0.1:{gw.port}/v1/runs/r1/renew'}))
        started = time.monotonic()
        r = graff(binary, box, gw, 'remote-control', '--name', 'cloud-test', key=None, timeout=40)
        took = time.monotonic() - started
        gw.stop()
        renews = [p for m, p in gw.calls if p == '/v1/runs/r1/renew']
        assert len(renews) == 2, gw.calls
        assert 'run r1 ended (run_revoked)' in r.stderr + r.stdout, r.stderr[-800:]
        assert took < 30, took
        device_auth = [a for p, a in gw.auth if p.startswith('/v1/remote/agents/')]
        assert device_auth and all(a == f'Bearer {TOKEN}' for a in device_auth), device_auth[:3]
        shutil.rmtree(box, ignore_errors=True)
        print(f'PASS remote-control renews its run token and exits on revoke ({took:.1f}s)', flush=True)
    finally:
        shutil.rmtree(home, ignore_errors=True)


if __name__ == '__main__':
    main()
