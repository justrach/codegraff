#!/usr/bin/env python3
"""`graff peer` over the account's swarm channel, against a mock hub.

Cloud peers are off until `graff peer cloud on`; then local agents join as
members, reach cloud agents by name, post to the channel, and read mentions
and DMs with a server-side cursor. Off again, nothing leaves the device.
"""
import json, os, shutil, subprocess, sys, tempfile, threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlparse, parse_qs

ME = 'claude-codegraff'


class Hub:
    def __init__(self):
        self.calls, self.members, self.posts, self.acks = [], [], [], []
        self.msgs = []
        hub = self

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
                return json.loads(self.rfile.read(n)) if n else {}

            def do_GET(self):
                u = urlparse(self.path)
                hub.calls.append(('GET', self.path))
                if u.path == '/v1/swarm':
                    return self.reply(200, {'members': [
                        {'name': ME, 'kind': 'external', 'host': 'mac', 'online': True},
                        {'name': 'vm-mimo', 'kind': 'external', 'host': 'sandbox', 'online': True},
                        {'name': 'reviewer', 'kind': 'hub', 'host': '', 'online': False}]})
                if u.path == '/v1/swarm/messages':
                    q = parse_qs(u.query)
                    start = int(q.get('from', ['1'])[0])
                    who = q.get('for', [''])[0]
                    got = [m for m in hub.msgs if m['seq'] >= start and (not who or who in m['mentions'] or m.get('to') == who)]
                    nxt = (hub.msgs[-1]['seq'] + 1) if hub.msgs and hub.msgs[-1]['seq'] >= start else start
                    return self.reply(200, {'messages': got, 'next_from': nxt, 'gap': False})
                return self.reply(404, {})

            def do_POST(self):
                b = self.body()
                hub.calls.append(('POST', self.path))
                if self.path == '/v1/swarm/members':
                    hub.members.append(b)
                    return self.reply(201, {'member': b})
                if self.path == '/v1/swarm/messages':
                    hub.posts.append(b)
                    return self.reply(201, {'message': b})
                if self.path.endswith('/ack'):
                    hub.acks.append((self.path, b))
                    return self.reply(200, {})
                return self.reply(404, {})

        self.server = ThreadingHTTPServer(('127.0.0.1', 0), H)
        self.port = self.server.server_address[1]
        threading.Thread(target=self.server.serve_forever, daemon=True).start()


def main():
    if os.name != 'posix':
        print('peer cloud test: POSIX only')
        return
    binary = str(Path(sys.argv[1] if len(sys.argv) > 1 else 'zig-out/bin/graff').resolve())
    home = Path(tempfile.mkdtemp(prefix='peer-cloud-'))
    hub = Hub()
    env = {'HOME': str(home), 'PATH': os.environ.get('PATH', '/usr/bin:/bin'), 'GRAFF_NO_TELEMETRY': '1',
           'GRAFF_GATEWAY_BASE': f'http://127.0.0.1:{hub.port}', 'CODEGRAFF_API_KEY': 'cg_sk_test', 'TERM': 'dumb'}

    def peer(*args):
        return subprocess.run([binary, 'peer', *args, '--as', 'claude@codegraff'], env=env, cwd=home,
                              capture_output=True, text=True, timeout=30)
    try:
        r = peer('send', '--to', 'vm-mimo', 'hello')
        assert r.returncode != 0 and not hub.calls, (r.returncode, hub.calls, r.stdout, r.stderr)
        print('PASS cloud off by default: nothing leaves the device', flush=True)

        r = peer('cloud', 'on')
        assert r.returncode == 0 and f'@{ME}' in r.stdout, r.stdout + r.stderr
        assert hub.members and hub.members[-1]['name'] == ME and hub.members[-1]['kind'] == 'external', hub.members
        print('PASS cloud on registers the agent as an external member', flush=True)

        r = peer('list')
        assert '@vm-mimo' in r.stdout and 'online' in r.stdout and '@reviewer' in r.stdout, r.stdout
        assert f'@{ME}' not in r.stdout.split('you:')[1].split('\n', 1)[1], 'lists itself as a cloud peer'
        print('PASS peer list shows cloud members', flush=True)

        r = peer('send', '--to', 'vm-mimo', 'can you run the tests?')
        assert r.returncode == 0 and 'through your cloud channel' in r.stdout, r.stdout + r.stderr
        assert hub.posts[-1] == {'body': 'can you run the tests?', 'from': ME, 'to': 'vm-mimo'}, hub.posts[-1]
        r = peer('send', '--cloud', 'status: PR is green')
        assert r.returncode == 0 and hub.posts[-1] == {'body': 'status: PR is green', 'from': ME}, hub.posts
        print('PASS DMs fall through to the cloud; --cloud posts to the channel', flush=True)

        hub.msgs = [
            {'seq': 4, 'from': 'reviewer', 'body': 'unrelated', 'mentions': [], 'hop': 1, 'ts': 1},
            {'seq': 5, 'from': 'vm-mimo', 'body': f'@{ME} tests pass', 'mentions': [ME], 'hop': 1, 'ts': 2},
            {'seq': 6, 'from': 'vm-mimo', 'to': ME, 'body': 'dm: want the log?', 'mentions': [], 'hop': 1, 'ts': 3}]
        r = peer('inbox', '--peek')
        assert 'tests pass' in r.stdout and not hub.acks, (r.stdout, hub.acks)
        r = peer('inbox')
        assert '[cloud vm-mimo] @claude-codegraff tests pass' in r.stdout, r.stdout
        assert '[cloud dm vm-mimo → claude-codegraff] dm: want the log?' in r.stdout and 'unrelated' not in r.stdout, r.stdout
        assert hub.acks[-1] == (f'/v1/swarm/members/{ME}/ack', {'upto_seq': 6}), hub.acks
        r = peer('inbox')
        assert 'no new messages' in r.stdout, r.stdout
        print('PASS inbox reads mentions and DMs, then acks the server cursor', flush=True)

        r = peer('cloud', 'off')
        n = len(hub.calls)
        r = peer('send', '--to', 'vm-mimo', 'still there?')
        assert r.returncode != 0 and len(hub.calls) == n, (r.returncode, hub.calls[n:])
        print('PASS cloud off stops all backend traffic', flush=True)
    finally:
        hub.server.shutdown()
        shutil.rmtree(home, ignore_errors=True)


if __name__ == '__main__':
    main()
