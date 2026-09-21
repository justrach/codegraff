#!/usr/bin/env python3
"""Install a private local MCP service and merge detected client configs."""
import argparse
import fcntl
import json
import os
from pathlib import Path
import plistlib
import re
import secrets
import shutil
import subprocess
import sys
import tempfile
import time
import urllib.request

MARKER = '# Codegraff managed MCP service'


def atomic(path, text):
    path.parent.mkdir(parents=True, exist_ok=True)
    if path.is_symlink():
        raise ValueError(f'Refusing symlink: {path.name}')
    fd, temporary = tempfile.mkstemp(dir=path.parent, prefix='.graff-')
    try:
        os.fchmod(fd, 0o600)
        with os.fdopen(fd, 'w') as stream:
            stream.write(text)
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def merge_json(path, entry, key='mcpServers', previous=None):
    data = json.loads(path.read_text()) if path.exists() else {}
    if not isinstance(data, dict) or not isinstance(data.get(key, {}), dict):
        raise ValueError('Unexpected config structure')
    servers = data.setdefault(key, {})
    if 'codegraff' in servers and (previous is None or servers['codegraff'] != previous):
        return 'existing entry preserved'
    if servers.get('codegraff') == entry:
        return 'up to date'
    servers['codegraff'] = entry
    atomic(path, json.dumps(data, indent=2) + '\n')
    return 'registered'


def codex_entry(url, token):
    return {'url': url, 'http_headers': {'Authorization': 'Bearer ' + token}, 'tool_timeout_sec': 330}


def codex_fragment(entry):
    return ('\n[mcp_servers.codegraff]\nurl = ' + json.dumps(entry['url']) + '\n' +
            'http_headers = { Authorization = ' + json.dumps(entry['http_headers']['Authorization']) + ' }\n' +
            'tool_timeout_sec = ' + str(entry['tool_timeout_sec']) + '\n')


def merge_codex(path, url, token, previous=None):
    # Preserve the entire TOML document, including comments and unfamiliar tables.
    source = path.read_text() if path.exists() else ''
    try:
        import tomllib
    except ImportError:
        raise ValueError('Codex registration requires Python 3.11+ for TOML validation')
    data = tomllib.loads(source)
    if not isinstance(data.get('mcp_servers', {}), dict):
        raise ValueError('Unexpected MCP server table')
    entry = codex_entry(url, token)
    current = data.get('mcp_servers', {}).get('codegraff')
    if current is not None:
        if previous is None or current != previous:
            return 'existing entry preserved'
        if current == entry:
            return 'up to date'
        old = codex_fragment(previous)
        if source.count(old) != 1:
            return 'existing entry preserved'
        updated = source.replace(old, codex_fragment(entry), 1)
    else:
        updated = source + codex_fragment(entry)
    tomllib.loads(updated)
    atomic(path, updated)
    return 'registered'


def register(home, url, token):
    receipt = home / '.graff/mcp/clients.json'
    owned = json.loads(receipt.read_text()) if receipt.exists() else {}
    if not isinstance(owned, dict):
        raise ValueError('Invalid client ownership receipt')
    changed = False
    headers = {'Authorization': 'Bearer ' + token}
    entries = [
        (home / '.claude.json', 'mcpServers', {'type': 'http', 'url': url, 'headers': headers}, (home / '.claude').exists()),
        (home / '.cursor/mcp.json', 'mcpServers', {'url': url, 'headers': headers}, False),
        (home / '.gemini/settings.json', 'mcpServers', {'httpUrl': url, 'headers': headers, 'timeout': 330000}, False),
        (home / '.codeium/windsurf/mcp_config.json', 'mcpServers', {'serverUrl': url, 'headers': headers}, False),
    ]
    vscode = home / ('Library/Application Support/Code/User' if sys.platform == 'darwin' else '.config/Code/User')
    entries.append((vscode / 'mcp.json', 'servers', {'type': 'http', 'url': url, 'headers': headers}, False))
    results = []
    for path, key, entry, detected in entries:
        if not (detected or path.exists() or (path.parent != home and path.parent.exists())):
            continue
        try:
            client = str(path.relative_to(home))
            result = merge_json(path, entry, key, owned.get(client))
            results.append((client, result))
            if result in ('registered', 'up to date'):
                owned[client] = entry
                changed = True
        except (ValueError, OSError) as error:
            results.append((str(path.relative_to(home)), f'skipped: {type(error).__name__}; original preserved'))
    codex = home / '.codex/config.toml'
    if codex.parent.exists():
        try:
            result = merge_codex(codex, url, token, owned.get('.codex/config.toml'))
            results.append(('.codex/config.toml', result))
            if result in ('registered', 'up to date'):
                owned['.codex/config.toml'] = codex_entry(url, token)
                changed = True
        except (ValueError, OSError) as error:
            results.append(('.codex/config.toml', f'skipped: {type(error).__name__}; original preserved'))
    if changed:
        atomic(receipt, json.dumps(owned, indent=2) + "\n")
    return results


def rpc(url, token, method, sid=None):
    headers = {'Authorization': 'Bearer ' + token, 'Content-Type': 'application/json',
               'Accept': 'application/json, text/event-stream', 'MCP-Protocol-Version': '2025-06-18'}
    if sid:
        headers['Mcp-Session-Id'] = sid
    request = urllib.request.Request(url, data=json.dumps({'jsonrpc': '2.0', 'id': 1,
        'method': method, 'params': {'protocolVersion': '2025-06-18', 'capabilities': {},
        'clientInfo': {'name': 'codegraff-installer', 'version': '1'}}}).encode(), headers=headers)
    # Never route loopback credentials through ambient HTTP proxies.
    with urllib.request.build_opener(urllib.request.ProxyHandler({})).open(request, timeout=2) as response:
        body = json.load(response)
        session = response.headers.get('Mcp-Session-Id')
    if session:
        request = urllib.request.Request(url, headers={**headers, 'Mcp-Session-Id': session}, method='DELETE')
        with urllib.request.build_opener(urllib.request.ProxyHandler({})).open(request, timeout=2):
            pass
    return body


def ready(url, token):
    try:
        return rpc(url, token, 'initialize')['result']['serverInfo']['name'] == 'codegraff'
    except (OSError, ValueError, KeyError):
        return False


def run_managed(argv, check=True):
    delay = 0.05
    for attempt in range(6):
        try:
            return subprocess.run(argv, check=check, capture_output=True, stdin=subprocess.DEVNULL)
        except BlockingIOError:
            if attempt == 5:
                raise
            time.sleep(delay)
            delay = min(delay * 2, 0.5)


def acquire_install_lock(lock_path, timeout=12.0):
    if lock_path.is_symlink():
        raise ValueError('Refusing symlinked installer lock')
    install_lock = open(lock_path, 'a')
    os.chmod(lock_path, 0o600)
    deadline = time.monotonic() + timeout
    while True:
        try:
            fcntl.flock(install_lock.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
            return install_lock
        except BlockingIOError:
            if time.monotonic() >= deadline:
                install_lock.close()
                raise ValueError('another MCP install is already running; retry from Tools → Configure MCP clients')
            time.sleep(0.1)


def service(home, executable, directory, port, token):
    state = home / '.graff/mcp'
    command = [str(executable), 'mcp', 'serve', '--http', '--port', str(port)]
    if sys.platform == 'darwin':
        target = home / 'Library/LaunchAgents/dev.codegraff.mcp.plist'
        if target.exists() and plistlib.loads(target.read_bytes()).get('CodegraffManaged') != 1:
            raise ValueError('Existing launch agent is not managed by Codegraff')
        config = {'Label': 'dev.codegraff.mcp', 'CodegraffManaged': 1, 'ProgramArguments': command,
                  'WorkingDirectory': str(directory), 'EnvironmentVariables': {'GRAFF_MCP_TOKEN': token},
                  'RunAtLoad': True, 'KeepAlive': True, 'ThrottleInterval': 10,
                  'StandardOutPath': str(state / 'service.log'), 'StandardErrorPath': str(state / 'service.log')}
        atomic(target, plistlib.dumps(config).decode())
        domain = f'gui/{os.getuid()}'
        run_managed(['launchctl', 'bootout', domain + '/dev.codegraff.mcp'], check=False)
        run_managed(['launchctl', 'bootstrap', domain, str(target)])
        run_managed(['launchctl', 'kickstart', '-k', domain + '/dev.codegraff.mcp'])
    elif sys.platform.startswith('linux') and shutil.which('systemctl'):
        target = home / '.config/systemd/user/codegraff-mcp.service'
        if target.exists() and MARKER not in target.read_text():
            raise ValueError('Existing service is not managed by Codegraff')
        quote = lambda value: json.dumps(str(value).replace('%', '%%').replace('$', '$$'))
        atomic(target, MARKER + '\n[Unit]\nDescription=Codegraff local MCP\n[Service]\n' +
            'ExecStart=' + ' '.join(quote(part) for part in command) + '\n' +
            'WorkingDirectory=' + quote(directory) + '\nEnvironment=GRAFF_MCP_TOKEN=' + token +
            '\nRestart=on-failure\nRestartSec=10\n[Install]\nWantedBy=default.target\n')
        run_managed(['systemctl', '--user', 'daemon-reload'])
        run_managed(['systemctl', '--user', 'enable', '--now', 'codegraff-mcp.service'])
        run_managed(['systemctl', '--user', 'restart', 'codegraff-mcp.service'])
    else:
        raise ValueError('Automatic service setup needs macOS launchd or Linux user systemd')


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--binary', required=True)
    parser.add_argument('--directory')
    parser.add_argument('--port', type=int)
    args = parser.parse_args()
    if os.environ.get('GRAFF_NO_MCP') == '1':
        print('MCP setup skipped (GRAFF_NO_MCP=1)')
        return
    settings_path = Path.home() / '.graff/mcp/settings.json'
    settings = json.loads(settings_path.read_text()) if settings_path.exists() else {}
    args.port = args.port or settings.get('port', 7720)
    args.directory = args.directory or settings.get('directory', str(Path.home()))
    if not 1 <= args.port <= 65535:
        raise ValueError('Invalid port')
    home = Path.home()
    directory = Path(args.directory).resolve(strict=True)
    if not directory.is_dir():
        raise ValueError('Workspace must be a directory')
    binary = Path(args.binary).resolve(strict=True)
    state = home / '.graff/mcp'
    state.mkdir(parents=True, exist_ok=True, mode=0o700)
    if state.is_symlink():
        raise ValueError('Refusing symlinked service directory')
    os.chmod(state, 0o700)
    lock_path = state / 'install.lock'
    url = f'http://127.0.0.1:{args.port}/mcp'
    try:
        install_lock = acquire_install_lock(lock_path)
    except ValueError:
        token_path = state / 'token'
        token = token_path.read_text().strip() if token_path.exists() else ''
        if token and ready(url, token):
            print(f'MCP ready at {url}; another installer holds the lock.')
            return
        raise
    token_path = state / 'token'
    if token_path.is_symlink():
        raise ValueError('Refusing symlinked token')
    token = token_path.read_text().strip() if token_path.exists() else secrets.token_hex(32)
    if not re.fullmatch('[0-9a-f]{64}', token):
        raise ValueError('Invalid stored service token')
    atomic(token_path, token + '\n')
    service(home, binary, directory, args.port, token)
    for _ in range(30):
        if ready(url, token):
            break
        time.sleep(.2)
    else:
        raise ValueError('Service did not become ready; client configs were not changed')
    atomic(settings_path, json.dumps({'port': args.port, 'directory': str(directory)}))
    for client, result in register(home, url, token):
        print(f'{client}: {result}')
    print(f'MCP ready at {url}; workspace: {directory}; approval-gated tasks. Restart clients to load it.')


if __name__ == '__main__':
    try:
        main()
    except Exception as error:
        print(f'MCP setup failed: {type(error).__name__}: {error}', file=sys.stderr)
        sys.exit(1)
