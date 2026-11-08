#!/usr/bin/env python3
"""`graff mcp add` for anything, checked by connecting, and live join.

- a command entry is saved and verified: the tool count and names are printed
- a pasted Claude-style JSON snippet saves every server in it
- a missing command is saved but reported with an actionable hint
- a server that answers 401 points at `graff mcp login` (no TTY here)
- a server added by the agent mid-session is callable on its next request
- a bare name resolves from the curated list, then from the registry only
  when the publisher owns the name; needs and limitations stop the save
"""
import json, os, shutil, subprocess, sys, tempfile, threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parent / 'eval'))
from mock_model import ScriptedModel

SERVER = r"""
import sys, json
def out(o): sys.stdout.write(json.dumps(o) + "\n"); sys.stdout.flush()
for line in sys.stdin:
    try: m = json.loads(line)
    except ValueError: continue
    mid = m.get('id'); meth = m.get('method')
    if mid is None: continue
    if meth == 'initialize':
        out({"jsonrpc": "2.0", "id": mid, "result": {"protocolVersion": "2025-11-25", "capabilities": {"tools": {}}, "serverInfo": {"name": "demo", "version": "1"}}})
    elif meth == 'server/discover':
        out({"jsonrpc": "2.0", "id": mid, "error": {"code": -32601, "message": "Method not found"}})
    elif meth == 'tools/list':
        out({"jsonrpc": "2.0", "id": mid, "result": {"tools": [
            {"name": "echo", "description": "echo", "inputSchema": {"type": "object", "properties": {}}},
            {"name": "ping", "description": "ping", "inputSchema": {"type": "object", "properties": {}}}]}})
    elif meth == 'tools/call':
        out({"jsonrpc": "2.0", "id": mid, "result": {"content": [{"type": "text", "text": "echo ok from demo"}]}})
    else:
        out({"jsonrpc": "2.0", "id": mid, "result": {}})
"""


class Unauthorized(BaseHTTPRequestHandler):
    def _deny(self):
        self.send_response(401)
        self.send_header('WWW-Authenticate', 'Bearer resource_metadata="http://127.0.0.1/.well-known/oauth-protected-resource"')
        self.send_header('Content-Length', '0')
        self.end_headers()
    do_POST = do_GET = _deny
    def log_message(self, *a): pass


def directory(server_py):
    """codegraff.com/mcp.json and the MCP registry search, served locally."""
    catalog = {"version": 1, "servers": [
        {"slug": "demo-cat", "name": "Demo Cat", "aliases": ["kitty"], "config": {"command": sys.executable, "args": [server_py]}},
        {"slug": "keyed", "name": "Keyed", "config": {"command": sys.executable, "args": [server_py]},
         "needs": [{"env": "DEMO_KEY", "hint": "a demo key"}]},
        {"slug": "blocked", "name": "Blocked", "config": {"url": "https://example.invalid/mcp"}, "limitation": "sign-in is not supported yet."},
    ]}
    registry = {
        "acme": [{"server": {"name": "io.github.acme/acme", "packages": [
            {"registryType": "npm", "identifier": "@acme/mcp", "version": "2.1.0", "transport": {"type": "stdio"}}]}}],
        "lookalike": [{"server": {"name": "io.github.someone/lookalike-tools", "packages": [
            {"registryType": "npm", "identifier": "lookalike-tools"}]}}],
    }

    class Directory(BaseHTTPRequestHandler):
        def do_GET(self):
            path, _, query = self.path.partition('?')
            if path == '/mcp.json':
                body = catalog
            else:
                search = dict(p.split('=', 1) for p in query.split('&') if '=' in p).get('search', '')
                body = {"servers": registry.get(search, []), "metadata": {}}
            data = json.dumps(body).encode()
            self.send_response(200)
            self.send_header('Content-Type', 'application/json')
            self.send_header('Content-Length', str(len(data)))
            self.end_headers()
            self.wfile.write(data)
        def log_message(self, *a): pass

    httpd = ThreadingHTTPServer(('127.0.0.1', 0), Directory)
    threading.Thread(target=httpd.serve_forever, daemon=True).start()
    return httpd


def run(binary, cwd, env, *args, stdin=None):
    # Never hand graff the caller's terminal: `mcp add` opens the OAuth flow
    # when stdin is a TTY (mcp_cli.checkSaved), so a suite run by hand would
    # attempt a real sign-in instead of printing the `graff mcp login` hint.
    feed = {'input': stdin} if stdin is not None else {'stdin': subprocess.DEVNULL}
    r = subprocess.run([binary, 'mcp', *args], cwd=cwd, env=env, capture_output=True, text=True, encoding='utf-8', errors='replace', timeout=180, **feed)
    return r.stdout + r.stderr


def saved(cwd):
    return json.loads((Path(cwd) / '.mcp.json').read_text())['mcpServers']


def main():
    binary = str(Path(sys.argv[1] if len(sys.argv) > 1 else 'zig-out/bin/graff').resolve())
    temp = tempfile.mkdtemp(prefix='graff-mcp-add-')
    try:
        server = Path(temp) / 'server.py'
        server.write_text(SERVER)
        env = {k: v for k, v in os.environ.items() if not k.endswith('_API_KEY')}
        env.update(HOME=temp, GRAFF_NO_TELEMETRY='1', GRAFF_FLEET='off', GRAFF_MCP_CONFIG=str(Path(temp) / 'global.json'))
        (Path(temp) / 'global.json').write_text('{"mcpServers":{}}')
        lookup = directory(str(server))
        base = f'http://127.0.0.1:{lookup.server_address[1]}'
        env.update(GRAFF_MCP_CATALOG_URL=f'{base}/mcp.json', GRAFF_MCP_REGISTRY_URL=f'{base}/v0.1/servers')
        work = Path(temp) / 'proj'
        work.mkdir()

        text = run(binary, work, env, 'add', 'demo', '--', sys.executable, str(server))
        assert '✓ demo works: 2 tool(s) — echo, ping' in text, text
        print('PASS mcp add: a command entry is saved, connected, and its tools listed', flush=True)

        snippet = json.dumps({"mcpServers": {"Snippet-One": {"command": sys.executable, "args": [str(server)]},
                                             "missing": {"command": "graff-no-such-binary-xyz", "args": []}}})
        text = run(binary, work, env, 'add', snippet)
        servers = saved(work)
        assert 'snippet-one' in servers and 'missing' in servers, servers
        assert '✓ snippet-one works: 2 tool(s)' in text, text
        assert '✗ saved missing, but it did not connect' in text and 'not found on PATH' in text, text
        print('PASS mcp add: a pasted JSON snippet saves every server; a missing command gets a hint', flush=True)

        httpd = ThreadingHTTPServer(('127.0.0.1', 0), Unauthorized)
        threading.Thread(target=httpd.serve_forever, daemon=True).start()
        try:
            url = f'http://127.0.0.1:{httpd.server_address[1]}/mcp'
            text = run(binary, work, env, 'add', url)
            name = f'local-{httpd.server_address[1]}'
            assert saved(work)[name]['url'] == url, saved(work)
            assert f'needs sign-in: run `graff mcp login {name}`' in text, text
        finally:
            httpd.shutdown()
        print('PASS mcp add: a URL is named from its host; a 401 points at graff mcp login', flush=True)

        names = Path(temp) / 'names'
        names.mkdir()
        text = run(binary, names, env, 'add', 'kitty')
        assert 'found Demo Cat via codegraff.com/mcp' in text and '✓ demo-cat works: 2 tool(s)' in text, text
        text = run(binary, names, env, 'add', 'keyed')
        assert 'DEMO_KEY: a demo key' in text and 'nothing was saved' in text and 'keyed' not in saved(names), text
        text = run(binary, names, env, 'add', 'keyed', '--env', 'DEMO_KEY=abc')
        assert saved(names)['keyed']['env'] == {'DEMO_KEY': 'abc'} and '✓ keyed works' in text, text
        text = run(binary, names, env, 'add', 'blocked')
        assert 'sign-in is not supported yet' in text and 'blocked' not in saved(names), text
        text = run(binary, names, env, 'add', 'acme', '--no-verify')
        assert 'found io.github.acme/acme via the MCP registry' in text, text
        assert saved(names)['acme'] == {'command': 'npx', 'args': ['-y', '@acme/mcp@2.1.0']}, saved(names)
        text = run(binary, names, env, 'add', 'lookalike')
        assert 'io.github.someone/lookalike-tools' in text and 'will not pick one' in text and 'lookalike' not in saved(names), text
        print('PASS mcp add <name>: the curated list first, the registry only for a publisher that owns the name', flush=True)

        text = run(binary, names, env, 'add', 'kitty', '--name', 'everywhere-cat', '--everywhere')
        global_servers = json.loads((Path(temp) / 'global.json').read_text())['mcpServers']
        assert 'everywhere-cat' in global_servers and 'everywhere-cat' not in saved(names), (global_servers, saved(names))
        assert '✓ everywhere-cat works' in text and 'global.json' in text, text
        print('PASS mcp add --everywhere: the user-level file gets the entry, the project file does not', flush=True)

        live = Path(temp) / 'live'
        live.mkdir()
        add_cmd = f'{binary} mcp add livedemo --no-verify -- {sys.executable} {server}'
        model = ScriptedModel([
            {'tool': 'bash', 'arguments': {'command': add_cmd}},
            {'tool': 'mcp__livedemo__echo', 'arguments': {}},
            {'text': 'Done.'},
        ])
        port = model.start(0)
        # No GRAFF_MCP_CONFIG here: an empty override is MCP's off-switch (#549).
        env2 = {k: v for k, v in env.items() if k != 'GRAFF_MCP_CONFIG'}
        env2.update(AI_GATEWAY_API_KEY='local', GRAFF_VERCEL_URL=f'http://127.0.0.1:{port}/v1/chat/completions',
                    GRAFF_NO_SMOLIFY='1', GRAFF_NO_CODEDB_GUARD='1')
        try:
            subprocess.run([binary, '--model', 'vercel', '--old', '--no-lean', '--yolo', '-p', 'add the demo server and use it'],
                           cwd=live, env=env2, stdin=subprocess.DEVNULL, capture_output=True, text=True, encoding='utf-8', errors='replace', timeout=180)
        finally:
            model.stop()
        results = [m.get('content') for m in model.requests[-1].get('messages', []) if m.get('role') == 'tool']
        assert any('echo ok from demo' in str(r) for r in results), results
        print('PASS live join: a server the agent adds mid-session is callable on its next request', flush=True)
    finally:
        shutil.rmtree(temp, ignore_errors=True)


if __name__ == '__main__':
    main()
