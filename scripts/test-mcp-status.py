#!/usr/bin/env python3
"""`graff mcp status | reconnect | enable | disable` against scripted servers.

Offline: no model, no network. Covers:
- two servers sharing one launcher command, differing only in `cwd`, get
  their own cached catalogs (they used to advertise each other's tools)
- a server's `env` overlays graff's environment (PATH survives)
- "enabled": false in an entry keeps it off until `graff mcp enable`
- `graff mcp disable` switches a server off and reconnect --all skips it
- a server that fails to start reports its own last stderr line
"""
import json, os, shutil, subprocess, sys, tempfile
from pathlib import Path

SERVER = r"""
import json, os, sys
if os.environ.get("STATUS_FAIL"):
    sys.stderr.write("starting\n" + os.environ["STATUS_FAIL"] + "\n"); sys.exit(2)
name = os.path.basename(os.getcwd()) + ("_has_path" if os.environ.get("PATH") else "_no_path")
def out(o): sys.stdout.write(json.dumps(o) + "\n"); sys.stdout.flush()
for line in sys.stdin:
    try: m = json.loads(line)
    except ValueError: continue
    mid = m.get("id"); meth = m.get("method")
    if mid is None: continue
    if meth == "initialize":
        out({"jsonrpc": "2.0", "id": mid, "result": {"protocolVersion": "2025-11-25", "capabilities": {"tools": {}}, "serverInfo": {"name": "s", "version": "1"}}})
    elif meth == "tools/list":
        out({"jsonrpc": "2.0", "id": mid, "result": {"tools": [{"name": name, "description": "tool of " + name + "\nmore", "inputSchema": {"type": "object"}}]}})
    elif meth == "server/discover":
        out({"jsonrpc": "2.0", "id": mid, "error": {"code": -32601, "message": "Method not found"}})
    else:
        out({"jsonrpc": "2.0", "id": mid, "result": {}})
"""


def graff(binary, work, env, *args):
    proc = subprocess.run([binary, 'mcp', *args, '--json'], cwd=work, env=env, capture_output=True, text=True, timeout=120)
    assert proc.returncode == 0, (args, proc.stdout, proc.stderr)
    return {row['name']: row for row in json.loads(proc.stdout)['servers']}


def main():
    binary = str(Path(sys.argv[1] if len(sys.argv) > 1 else 'zig-out/bin/graff').resolve())
    temp = Path(tempfile.mkdtemp(prefix='graff-mcp-status-'))
    try:
        (temp / 'server.py').write_text(SERVER)
        work = temp / 'proj'
        work.mkdir()
        for d in ('alpha', 'beta'):
            (temp / d).mkdir()
        launcher = {'command': sys.executable, 'args': [str(temp / 'server.py')]}
        cfg = {'mcpServers': {
            'alpha': {**launcher, 'cwd': str(temp / 'alpha')},
            'beta': {**launcher, 'cwd': str(temp / 'beta')},
            'tokened': {**launcher, 'cwd': str(temp / 'alpha'), 'env': {'SOME_TOKEN': 'x'}},
            'parked': {**launcher, 'cwd': str(temp / 'beta'), 'enabled': False},
            'broken': {**launcher, 'env': {'STATUS_FAIL': 'broken: not licensed. Run: broken activate'}},
        }}
        (work / '.mcp.json').write_text(json.dumps(cfg))
        env = {k: v for k, v in os.environ.items() if not k.endswith('_API_KEY')}
        env.update(HOME=str(temp), GRAFF_NO_TELEMETRY='1', GRAFF_FLEET='off', GRAFF_NO_PLUGINS='1')

        rows = graff(binary, work, env, 'status')
        assert set(rows) == {'alpha', 'beta', 'tokened', 'parked', 'broken'}, rows
        assert rows['alpha']['state'] == 'unknown' and rows['alpha']['source'] == 'project', rows['alpha']
        assert rows['parked']['state'] == 'off' and not rows['parked']['enabled'], rows['parked']

        rows = graff(binary, work, env, 'reconnect', '--all')
        assert 'parked' not in rows, rows  # switched off: not started
        assert rows['alpha']['state'] == 'ready', rows['alpha']
        assert [t['name'] for t in rows['alpha']['tools']] == ['alpha_has_path'], rows['alpha']
        assert [t['name'] for t in rows['beta']['tools']] == ['beta_has_path'], rows['beta']
        assert rows['alpha']['tools'][0]['description'] == 'tool of alpha_has_path', rows['alpha']
        # env overlays the parent environment: PATH is still there.
        assert [t['name'] for t in rows['tokened']['tools']] == ['alpha_has_path'], rows['tokened']
        assert rows['broken']['state'] == 'failed', rows['broken']
        assert rows['broken']['detail'] == 'broken: not licensed. Run: broken activate', rows['broken']

        # Cached per cwd: the next listing keeps each server's own tools, and a
        # failed server stays failed (with its own words) until it starts.
        rows = graff(binary, work, env, 'status')
        assert rows['broken']['state'] == 'failed', rows['broken']
        assert rows['broken']['detail'] == 'broken: not licensed. Run: broken activate', rows['broken']
        assert rows['alpha']['state'] == 'on_demand' and rows['alpha']['tools'][0]['name'] == 'alpha_has_path', rows['alpha']
        assert rows['beta']['tools'][0]['name'] == 'beta_has_path', rows['beta']

        rows = graff(binary, work, env, 'enable', 'parked')
        # Same launch as beta, so beta's reconnect already cached its tools.
        assert rows['parked']['enabled'] and rows['parked']['state'] == 'on_demand', rows['parked']
        rows = graff(binary, work, env, 'reconnect', 'parked')
        assert rows['parked']['state'] == 'ready', rows['parked']

        rows = graff(binary, work, env, 'disable', 'beta')
        assert rows['beta']['state'] == 'off', rows['beta']
        rows = graff(binary, work, env, 'reconnect', '--all')
        assert 'beta' not in rows and rows['alpha']['state'] == 'ready', rows
        state = json.loads((temp / '.codegraff' / 'mcp-state.json').read_text())
        assert state == {'disabled': ['beta'], 'enabled': ['parked']}, state
        print('mcp status: ok')
    finally:
        shutil.rmtree(temp, ignore_errors=True)


if __name__ == '__main__':
    main()
