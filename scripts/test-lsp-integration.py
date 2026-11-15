#!/usr/bin/env python3
"""Offline native LSP integration: built graff + installed clangd + loopback model.

No builds, downloads, real model calls, credentials, user projects, or GUI.
Usage: python3 scripts/test-lsp-integration.py --graff zig-out/bin/graff
An unavailable clangd is an explicit skip (exit 77), never a passing test.
"""
from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import queue
import re
import shutil
import signal
import subprocess
import sys
import tempfile
import threading
import time
from urllib.parse import unquote, urlsplit

sys.path.insert(0, str(Path(__file__).resolve().parent / 'eval'))
from mock_model import ScriptedModel

SOURCE = 'int twice(int value) { return value * 2; }\nint main() { return twice(21); }\n'
BROKEN = 'int main() { return missing_symbol; }\n'
POSITION = {'line': 2, 'character': SOURCE.splitlines()[1].index('twice') + 1}
DONE = 'LSP_FIXTURE_DONE'


def require(condition, message):
    if not condition:
        raise AssertionError(message)


def stop(proc):
    """Kill only our process group, including helper/server descendants."""
    if os.name == 'posix':
        try:
            os.killpg(proc.pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
    elif proc.poll() is None:
        proc.terminate()
    try:
        proc.wait(timeout=3)
    except subprocess.TimeoutExpired:
        if os.name == 'posix':
            os.killpg(proc.pid, signal.SIGKILL)
        else:
            proc.kill()
        proc.wait(timeout=3)


def invoke(binary, cwd, env, words, stdin=None, timeout=45):
    proc = subprocess.Popen([binary, *words], cwd=cwd, env=env, stdin=subprocess.PIPE,
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                            text=True, encoding='utf-8', start_new_session=True)
    try:
        stdout, stderr = proc.communicate(stdin, timeout=timeout)
        return proc.returncode, stdout, stderr
    finally:
        stop(proc)
        for stream in (proc.stdin, proc.stdout, proc.stderr):
            stream.close()


def tool_names(body):
    """Include deferred native schemas as well as immediately exposed tools."""
    names = set()
    for tool in body.get('tools', []):
        function = tool.get('function', tool)
        names.add(function.get('name'))
        if function.get('name') == 'load_tool_schemas':
            folded = re.search(r'Folded native:\s*([^;]+);', function.get('description', ''))
            if folded:
                names.update(name.strip() for name in folded.group(1).split(','))
    return names


def tool_text(body):
    return [message.get('content', '') for message in body.get('messages', [])
            if message.get('role') == 'tool']


def reply_json(body):
    """Tool wrappers may decorate a JSON reply with a short textual prefix."""
    for text in reversed(tool_text(body)):
        if not isinstance(text, str):
            continue
        decoder = json.JSONDecoder()
        for index, character in enumerate(text):
            if character != '{':
                continue
            try:
                value, _ = decoder.raw_decode(text[index:])
            except ValueError:
                continue
            if isinstance(value, dict) and value.get('version') == 1 and 'complete' in value:
                return value
    raise AssertionError('model did not receive a versioned LSP tool result')


def complete(reply, operation):
    require(reply.get('version') == 1 and reply.get('operation') == operation,
            f'{operation}: wrong response envelope')
    require(reply.get('complete') is True and 'error' not in reply,
            f'{operation}: incomplete/error response: {reply.get("error")}')
    return reply['result']


class Fixture:
    def __init__(self, base, name, binary, clangd):
        self.root = base / name
        self.root.mkdir()
        self.home = self.root / 'home'
        self.home.mkdir()
        self.binary, self.clangd = binary, clangd
        self.settings = self.root / '.harness/settings.json'
        self.settings.parent.mkdir()
        self.config = {'ai_title': False, 'session_recap': False,
                       'skills': {'codedbpro': False, 'muonry': False}}
        self.env = {key: os.environ[key] for key in (
            'PATH', 'PATHEXT', 'TMPDIR', 'TEMP', 'TMP',
            'SystemRoot', 'SystemDrive', 'WINDIR', 'COMSPEC',
            'APPDATA', 'LOCALAPPDATA',
        ) if key in os.environ}
        self.env.update(HOME=str(self.home), USERPROFILE=str(self.home),
                        XDG_CONFIG_HOME=str(self.home / '.config'),
                        XDG_CACHE_HOME=str(self.home / '.cache'),
                        GRAFF_NO_TELEMETRY='1', GRAFF_BEHAVIOR_UPLOAD='off',
                        GRAFF_FLEET='off', GRAFF_LEARN_AUTO='off', GRAFF_NO_SMOLIFY='1',
                        GRAFF_AUTO_ISOLATE='0', GRAFF_NO_BROWSER='1', NO_COLOR='1')
        mcp = self.root / 'empty-mcp.json'
        mcp.write_text('{"mcpServers":{}}')
        self.env['GRAFF_MCP_CONFIG'] = str(mcp)
        (self.root / 'source.cpp').write_text(SOURCE)
        self.save()

    def save(self):
        self.settings.write_text(json.dumps(self.config))

    def configure(self, command=None, timeout=20000, server_id='clangd'):
        self.config['lsp'] = {'servers': [{'id': server_id,
            'command': command or [self.clangd, '--background-index=false'],
            'extensions': ['.cpp'], 'language_id': 'cpp', 'timeout_ms': timeout}]}
        self.save()

    def marker_server(self, timeout=500):
        marker = self.root / 'server-started'
        script = self.root / 'marker-server.py'
        script.write_text('import os,sys,time\nfrom pathlib import Path\n'
                          'Path(sys.argv[1]).write_text(str(os.getpid()))\ntime.sleep(60)\n')
        self.configure([sys.executable, str(script), str(marker)], timeout)
        return marker

    def cli(self, *words, ok=True, flags=()):
        code, stdout, stderr = invoke(self.binary, self.root, self.env, [*flags, 'lsp', *words])
        require((code == 0) == ok,
                f'CLI {words[0]} unexpected exit {code}: {(stdout + stderr)[-900:]}')
        try:
            return json.loads(stdout)
        except ValueError:
            require(not ok, f'CLI {words[0]} did not return JSON')
            return {'text': stdout + stderr}

    def router(self, port):
        path = self.root / '.graff/.config.router'
        path.parent.mkdir(exist_ok=True)
        path.write_text(json.dumps({'id': 'lspfixture', 'base_url': f'http://127.0.0.1:{port}/v1',
                                   'env_key': 'LSP_FIXTURE_API_KEY', 'default_model': 'mock'}))
        self.env['LSP_FIXTURE_API_KEY'] = 'synthetic-loopback-only'

    def model_run(self, script, flags=()):
        model = ScriptedModel(script)
        port = model.start(0)
        self.router(port)
        try:
            code, stdout, stderr = invoke(self.binary, self.root, self.env,
                ['--json', '--yolo', '--old', '--no-lean', '--no-resume', '--no-telemetry',
                 '--model', 'lspfixture/mock', '--max-model-calls', '8', *flags],
                json.dumps({'type': 'user', 'text': 'Run the offline LSP fixture.'}) + '\n', 65)
            require(code == 0, f'JSON REPL exited {code}: {(stdout + stderr)[-900:]}')
            require(DONE in stdout, 'JSON REPL did not finish the scripted turn')
            events = [json.loads(line) for line in stdout.splitlines() if line.startswith('{')]
            require(events, 'JSON REPL emitted no structured events')
            return model.requests, events
        finally:
            model.stop()


class Acp:
    def __init__(self, fixture):
        self.proc = subprocess.Popen([fixture.binary, 'acp', '--yolo', '--old', '--no-lean',
            '--no-telemetry', '--model', 'lspfixture/mock'], cwd=fixture.root, env=fixture.env,
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            text=True, encoding='utf-8', start_new_session=True)
        self.events, self.errors, self.messages = [], [], queue.Queue()
        self.threads = [threading.Thread(target=self.read, daemon=True),
                        threading.Thread(target=lambda: self.errors.extend(self.proc.stderr), daemon=True)]
        for thread in self.threads:
            thread.start()
        self.next_id = 0

    def read(self):
        for line in self.proc.stdout:
            try:
                self.messages.put(json.loads(line))
            except ValueError:
                self.messages.put({'invalid_stdout': True})
        self.messages.put({'eof': True})

    def request(self, method, params):
        self.next_id += 1
        self.proc.stdin.write(json.dumps({'jsonrpc': '2.0', 'id': self.next_id,
                                         'method': method, 'params': params}) + '\n')
        self.proc.stdin.flush()
        deadline = time.monotonic() + 45
        while time.monotonic() < deadline:
            try:
                event = self.messages.get(timeout=max(.01, deadline - time.monotonic()))
            except queue.Empty:
                break
            require(not event.get('eof') and not event.get('invalid_stdout'),
                    f'ACP exited or emitted invalid JSON during {method}: {"".join(self.errors)[-600:]}')
            self.events.append(event)
            if event.get('id') == self.next_id:
                require('error' not in event, f'ACP {method} returned an RPC error')
                return event['result']
        raise AssertionError(f'ACP {method} timed out')

    def close(self):
        stop(self.proc)
        for thread in self.threads:
            thread.join(timeout=3)
        for stream in (self.proc.stdin, self.proc.stdout, self.proc.stderr):
            stream.close()


def call(operation, **arguments):
    return {'tool': 'lsp', 'arguments': {'operation': operation, **arguments}}


def uri_matches(uri, expected_path):
    if not isinstance(uri, str):
        return False
    parsed = urlsplit(uri)
    if parsed.scheme != 'file' or parsed.netloc not in ('', 'localhost'):
        return False
    decoded = unquote(parsed.path)
    if os.name == 'nt' and len(decoded) > 2 and decoded[0] == '/' and decoded[2] == ':':
        decoded = decoded[1:]
    return Path(decoded).resolve() == expected_path.resolve()


def test_cli(f):
    status = f.cli('status')
    require(status['enabled'] is False and status['servers'] == [], 'LSP must default off')
    f.configure()
    status = f.cli('status')
    require(status['enabled'] and status['servers'][0]['id'] == 'clangd', 'configured status missing clangd')
    source = f.root / 'source.cpp'
    source.write_text(BROKEN)
    errors = complete(f.cli('diagnostics', 'source.cpp'), 'diagnostics')
    require(any(d.get('severity') == 1 and 'missing_symbol' in d.get('message', '') for d in errors),
            'real clangd did not report the current error')
    source.write_text(SOURCE)
    require(complete(f.cli('diagnostics', 'source.cpp'), 'diagnostics') == [],
            'diagnostics did not become clean after fixing the same file')
    hover = complete(f.cli('hover', 'source.cpp', str(POSITION['line']),
                           str(POSITION['character'])), 'hover')
    require('twice' in json.dumps(hover) and 'int' in json.dumps(hover), 'real clangd hover missing type')
    definitions = complete(f.cli('definition', 'source.cpp', '2', str(POSITION['character'])), 'definition')
    location = definitions[0] if isinstance(definitions, list) else definitions
    require(uri_matches(location.get('targetUri', location.get('uri')), source),
            'definition did not resolve to source.cpp')
    position = location.get('targetSelectionRange', location.get('range'))['start']
    require(position == {'line': 0, 'character': 4}, 'definition position is wrong')
    refs = complete(f.cli('references', 'source.cpp', '2', str(POSITION['character'])), 'references')
    require(len(refs) >= 2, 'real clangd did not return declaration and reference')
    symbols = complete(f.cli('document_symbols', 'source.cpp'), 'document_symbols')
    require({'twice', 'main'} <= {s.get('name') for s in symbols}, 'document symbols missing functions')


def test_boundaries(f):
    marker = f.marker_server()
    status = f.cli('status')
    require(status['enabled'] and not marker.exists(), 'status must never launch a server')
    outside = f.root.parent / 'outside.cpp'
    outside.write_text(SOURCE)
    for path in ('../outside.cpp', str(outside)):
        result = f.cli('diagnostics', path, ok=False)
        require(result.get('complete') is False and result.get('error'), 'outside path not refused')
        require(not marker.exists(), 'outside path launched the server')
    if os.name == 'posix':
        (f.root / 'escape.cpp').symlink_to(outside)
        result = f.cli('diagnostics', 'escape.cpp', ok=False)
        require(result.get('complete') is False and result.get('error'), 'symlink escape not refused')
        require(not marker.exists(), 'symlink escape launched the server')
    else:
        print('SKIP symlink escape (requires POSIX fixture)')
    f.cli('diagnostics', 'source.cpp', flags=('--no-local-tools',), ok=False)
    require(not marker.exists(), '--no-local-tools launched a server')
    f.config['policies'] = [{'action': 'tool.use', 'resource': 'lsp', 'effect': 'deny'}]
    f.save()
    denied = f.cli('diagnostics', 'source.cpp', ok=False)
    require('den' in json.dumps(denied).lower() and not marker.exists(), 'hard policy did not deny before launch')


def test_timeout(f):
    marker = f.marker_server(timeout=200)
    reply = f.cli('diagnostics', 'source.cpp', ok=False)
    require(marker.exists(), 'timeout fixture server never started')
    require(reply.get('complete') is False and reply.get('result') is None,
            'timeout was falsely reported as clean diagnostics')
    require(reply.get('error', {}).get('code') == 'timeout', 'timeout was not explicit')
    if os.name == 'posix':
        pid = int(marker.read_text())
        deadline = time.monotonic() + 3
        while time.monotonic() < deadline:
            try:
                os.kill(pid, 0)
            except ProcessLookupError:
                return
            time.sleep(.05)
        raise AssertionError('timed-out language server was not reaped')


def test_catalog_off(f):
    requests, _ = f.model_run([{'text': DONE}])
    require(requests and all('lsp' not in tool_names(r) for r in requests), 'default-off catalog advertises lsp')


def test_repl(f):
    f.configure()
    requests, _ = f.model_run([call('diagnostics', path='source.cpp'),
                             call('hover', path='source.cpp', **POSITION), {'text': DONE}])
    require(len(requests) == 3, 'JSON REPL made an unexpected number of model calls')
    require('lsp' in tool_names(requests[0]), 'configured JSON REPL catalog lacks lsp')
    require(complete(reply_json(requests[1]), 'diagnostics') == [], 'REPL diagnostics not clean')
    hover = complete(reply_json(requests[2]), 'hover')
    require('twice' in json.dumps(hover), 'REPL tool call did not reach real clangd')


def test_gate(f, policy=False):
    marker = f.marker_server()
    if policy:
        f.config['policies'] = [{'action': 'tool.use', 'resource': 'lsp', 'effect': 'deny'}]
        f.save()
    requests, _ = f.model_run([call('diagnostics', path='source.cpp'), {'text': DONE}],
                             flags=() if policy else ('--no-local-tools',))
    require(len(requests) == 2, 'gate fixture did not complete its tool roundtrip')
    result = ' '.join(tool_text(requests[1])).lower()
    require(('den' in result and 'policy' in result) if policy else '--no-local-tools' in result,
            'runtime did not reject the hallucinated lsp call')
    require(not marker.exists(), 'denied native tool launched its server')
    if not policy:
        require('lsp' not in tool_names(requests[0]), 'no-local-tools catalog advertises lsp')


def test_child(f, gated=False):
    marker = f.marker_server() if gated else None
    if not gated:
        f.configure()
    child = {'tool': 'subagent', 'arguments': {'description': 'LSP child probe',
             'prompt': 'Run the scripted read-only LSP query.', 'isolation': 'shared_cwd',
             'run_in_background': False}}
    requests, _ = f.model_run([child, call('hover', path='source.cpp', **POSITION),
                              {'text': 'child finished'}, {'text': DONE}],
                             flags=('--no-local-tools',) if gated else ())
    require(len(requests) == 4, 'foreground child did not complete its scripted roundtrip')
    require(('lsp' in tool_names(requests[1])) != gated, 'child LSP catalog inheritance is wrong')
    if gated:
        require('--no-local-tools' in ' '.join(tool_text(requests[2])) and not marker.exists(),
                'child did not inherit the runtime gate')
    else:
        require('twice' in json.dumps(complete(reply_json(requests[2]), 'hover')),
                'child inherited catalog but did not execute real clangd')


def test_acp(f):
    model = ScriptedModel([call('hover', path='source.cpp', server='clangd', **POSITION), {'text': DONE}])
    port = model.start(0)
    f.router(port)
    if os.name == 'posix':
        marker = f.marker_server()
        f.config['lsp']['servers'][0]['id'] = 'launch-only'
        f.save()
        client = Fixture(f.root, 'client-workspace', f.binary, f.clangd)
        client.configure()
        client.router(port)
        target_cwd = client.root
    else:
        marker = None
        f.configure()
        target_cwd = f.root
    acp = None
    try:
        acp = Acp(f)
        acp.request('initialize', {'protocolVersion': 1})
        created = acp.request('session/new', {'cwd': str(target_cwd), 'mcpServers': []})
        require(Path(created.get('_meta', {}).get('graff/cwd', '')).resolve() == target_cwd.resolve(),
                'ACP did not adopt the client workspace')
        turn = acp.request('session/prompt', {'sessionId': created['sessionId'],
                           'prompt': [{'type': 'text', 'text': 'Run the offline LSP fixture.'}]})
        require(turn.get('stopReason') == 'end_turn', 'ACP scripted turn did not finish')
        require(len(model.requests) == 2 and 'lsp' in tool_names(model.requests[0]),
                'ACP client configuration did not expose lsp')
        hover = complete(reply_json(model.requests[1]), 'hover')
        require('twice' in json.dumps(hover), 'ACP client-configured tool did not reach real clangd')
        if marker is not None:
            require(not marker.exists(), 'ACP launched the daemon-cwd server instead of client configuration')
        updates = [e['params']['update'] for e in acp.events if e.get('method') == 'session/update']
        require(any(u.get('sessionUpdate') == 'tool_call' and
                    u.get('_meta', {}).get('graff/toolName') == 'lsp' for u in updates),
                'ACP did not publish the native lsp tool call')
    finally:
        if acp:
            acp.close()
        model.stop()


def test_global_default_and_setup(f):
    setup_reply = f.cli('setup', '--check')
    require(setup_reply.get('version') == 1 and setup_reply.get('check_only') is True,
            'lsp setup --check did not report check_only JSON')
    require(f.cli('status')['enabled'] is False, 'clean workspace without global config must start off')
    global_cfg = f.home / '.graff' / 'lsp' / 'settings.json'
    global_cfg.parent.mkdir(parents=True, exist_ok=True)
    global_cfg.write_text(json.dumps({'lsp': {'servers': [{
        'id': 'clangd', 'command': [f.clangd, '--background-index=false'],
        'extensions': ['.cpp'], 'language_id': 'cpp', 'timeout_ms': 20000,
    }]}}))
    status = f.cli('status')
    require(status['enabled'] and [s['id'] for s in status['servers']] == ['clangd'],
            'home ~/.graff/lsp/settings.json was not loaded by default')
    require(complete(f.cli('diagnostics', 'source.cpp'), 'diagnostics') == [],
            'default home LSP did not serve unconfigured workspace')
    f.config['lsp'] = False
    f.save()
    require(f.cli('status')['enabled'] is False,
            'workspace lsp=false did not override global ~/.graff/lsp/settings.json')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--graff', default='zig-out/bin/graff')
    parser.add_argument('--clangd', default=shutil.which('clangd'))
    parser.add_argument('--allow-missing-clangd', action='store_true', help='permit an explicitly reported skip in portable build checks')
    args = parser.parse_args()
    binary = str(Path(args.graff).resolve())
    if not Path(binary).is_file():
        parser.error('built graff binary not found; build it separately')
    clangd = shutil.which(args.clangd) if args.clangd else None
    if not clangd:
        print('SKIP native LSP integration: installed clangd unavailable')
        return 0 if args.allow_missing_clangd else 77
    cases = [('CLI real clangd/current diagnostics/fix/navigation', test_cli),
             ('status/path confinement/CLI gates', test_boundaries),
             ('diagnostics timeout is incomplete and server reaped', test_timeout),
             ('default-off JSON REPL catalog', test_catalog_off),
             ('global default, override, opt-out, and lsp setup', test_global_default_and_setup),
             ('configured JSON REPL native tool', test_repl),
             ('JSON REPL no-local-tools runtime gate', test_gate),
             ('JSON REPL hard-policy runtime gate', lambda f: test_gate(f, policy=True)),
             ('foreground child LSP inheritance without MCP', test_child),
             ('foreground child no-local-tools inheritance', lambda f: test_child(f, gated=True)),
             ('ACP client-cwd catalog and real clangd execution', test_acp)]
    failures = 0
    with tempfile.TemporaryDirectory(prefix='graff-lsp-integration-') as temporary:
        base = Path(temporary).resolve()
        for index, (name, test) in enumerate(cases):
            fixture = Fixture(base, f'case-{index}', binary, clangd)
            try:
                test(fixture)
                print(f'PASS {name}', flush=True)
            except Exception as error:
                failures += 1
                detail = str(error).replace(str(base), '<fixture>').replace(binary, '<graff>')
                print(f'FAIL {name}: {detail}', flush=True)
    print(f'Native LSP integration: {len(cases) - failures}/{len(cases)} passed; all model traffic loopback')
    return int(failures != 0)


if __name__ == '__main__':
    raise SystemExit(main())
