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


def linux_user_systemd():
    if not shutil.which('systemctl'):
        return False
    return run_managed(['systemctl', '--user', 'show-environment'], check=False).returncode == 0


def start_detached(command, directory, token, log_path):
    log_path.parent.mkdir(parents=True, exist_ok=True)
    log = open(log_path, 'ab')
    env = os.environ.copy()
    env['GRAFF_MCP_TOKEN'] = token
    child = subprocess.Popen(command, cwd=str(directory), env=env, stdin=subprocess.DEVNULL,
                             stdout=log, stderr=log, start_new_session=True)
    log.close()
    return child


def systemd_unit(command, directory, token):
    """The user unit. ExecStart arguments are quoted words; WorkingDirectory is
    one literal path that systemd does not unquote (a quoted value is "not
    absolute"), so it only escapes the % specifier character."""
    directory = str(directory)
    if '\n' in directory or not directory.startswith('/'):
        raise ValueError('Workspace path cannot be written to a systemd unit')
    quote = lambda value: json.dumps(str(value).replace('%', '%%').replace('$', '$$'))
    return (MARKER + '\n[Unit]\nDescription=Codegraff local MCP\n[Service]\n' +
            'ExecStart=' + ' '.join(quote(part) for part in command) + '\n' +
            'WorkingDirectory=' + directory.replace('%', '%%') + '\nEnvironment=GRAFF_MCP_TOKEN=' + token +
            '\nRestart=on-failure\nRestartSec=10\n[Install]\nWantedBy=default.target\n')


def systemctl(*args):
    """systemctl --user, failing with systemd's own explanation."""
    result = run_managed(['systemctl', '--user', *args], check=False)
    if result.returncode != 0:
        detail = (result.stderr or b'').decode(errors='replace').strip() or f'exit {result.returncode}'
        raise ValueError(f'systemctl --user {" ".join(args)} failed: {detail}')
    return result


LABEL = 'dev.codegraff.mcp'
UNIT = 'codegraff-mcp.service'


def launchd_target():
    return f'gui/{os.getuid()}/{LABEL}'


def launchctl(*args):
    """launchctl, failing with launchd's own explanation."""
    result = run_managed(['launchctl', *args], check=False)
    if result.returncode != 0:
        detail = (result.stderr or result.stdout or b'').decode(errors='replace').strip() or f'exit {result.returncode}'
        raise ValueError(f'launchctl {" ".join(args)} failed: {detail}')
    return result


def job_path(home):
    if sys.platform == 'darwin':
        return home / 'Library/LaunchAgents' / (LABEL + '.plist')
    if sys.platform.startswith('linux'):
        return home / '.config/systemd/user' / UNIT
    return None


def managed_job(path):
    """The managed job file's bytes, None when absent; refuses one we did not write."""
    if path is None or not path.exists():
        return None
    content = path.read_bytes()
    if path.suffix == '.plist':
        if plistlib.loads(content).get('CodegraffManaged') != 1:
            raise ValueError('Existing launch agent is not managed by Codegraff')
    elif MARKER.encode() not in content:
        raise ValueError('Existing service is not managed by Codegraff')
    return content


def job_port(content):
    """The port a job file serves on, or None."""
    if not content:
        return None
    if content.lstrip().startswith(b'<'):
        words = plistlib.loads(content).get('ProgramArguments', [])
    else:
        line = next((l for l in content.decode(errors='replace').splitlines() if l.startswith('ExecStart=')), '')
        words = re.findall(r'"((?:[^"\\]|\\.)*)"', line)
    for flag, value in zip(words, words[1:]):
        if flag == '--port' and value.isdigit():
            return int(value)
    return None


def job_running():
    """(loaded, pid) as the service manager reports them; pid may be None."""
    if sys.platform == 'darwin':
        result = run_managed(['launchctl', 'print', launchd_target()], check=False)
        if result.returncode != 0:
            return False, None
        found = re.search(rb'^\s*pid = (\d+)', result.stdout or b'', re.M)
        return True, int(found.group(1)) if found else None
    if sys.platform.startswith('linux') and linux_user_systemd():
        result = run_managed(['systemctl', '--user', 'show', '-p', 'ActiveState', '-p', 'MainPID', UNIT], check=False)
        fields = dict(line.split('=', 1) for line in (result.stdout or b'').decode(errors='replace').splitlines() if '=' in line)
        pid = int(fields.get('MainPID', '0') or 0)
        return fields.get('ActiveState') in ('active', 'activating', 'reloading'), pid or None
    return False, None


def load_job(path):
    """Start the job in `path` under the service manager, replacing a loaded one."""
    if sys.platform == 'darwin':
        run_managed(['launchctl', 'bootout', launchd_target()], check=False)
        launchctl('bootstrap', launchd_target().rsplit('/', 1)[0], str(path))
        launchctl('kickstart', '-k', launchd_target())
    else:
        systemctl('daemon-reload')
        systemctl('enable', '--now', UNIT)
        systemctl('restart', UNIT)


def unload_job():
    if sys.platform == 'darwin':
        if job_running()[0]:
            launchctl('bootout', launchd_target())
    elif linux_user_systemd():
        systemctl('disable', '--now', UNIT)


def service(home, executable, directory, port, token):
    """Write and start the managed job. Returns the child when there is no
    service manager and the listener was started directly, else None."""
    state = home / '.graff/mcp'
    command = [str(executable), 'mcp', 'serve', '--http', '--port', str(port)]
    target = job_path(home)
    managed_job(target)
    if sys.platform == 'darwin':
        config = {'Label': LABEL, 'CodegraffManaged': 1, 'ProgramArguments': command,
                  'WorkingDirectory': str(directory), 'EnvironmentVariables': {'GRAFF_MCP_TOKEN': token},
                  'RunAtLoad': True, 'KeepAlive': True, 'ThrottleInterval': 10,
                  'StandardOutPath': str(state / 'service.log'), 'StandardErrorPath': str(state / 'service.log')}
        atomic(target, plistlib.dumps(config).decode())
        load_job(target)
        return None
    if sys.platform.startswith('linux'):
        atomic(target, systemd_unit(command, directory, token))
        if linux_user_systemd():
            load_job(target)
            return None
        return start_detached(command, directory, token, home / '.graff/mcp/service.log')
    raise ValueError('Automatic service setup needs macOS launchd or Linux user systemd')


def snapshot(home):
    """What a failed install must put back: the previous job file (None on a
    first install), whether it was running, and the port it served."""
    content = managed_job(job_path(home))
    running = content is not None and job_running()[0]
    return content, running, job_port(content)


def rollback(home, previous, child):
    """Undo a service change that never became ready. Every step is tried even
    when an earlier one fails; returns (what is in place now, errors)."""
    content, running, port = previous
    path = job_path(home)
    errors = []
    if path is None:
        return 'nothing was installed', errors

    def attempt(step, *args):
        try:
            step(*args)
        except (OSError, ValueError, subprocess.SubprocessError) as error:
            errors.append(str(error))

    systemd = sys.platform.startswith('linux') and linux_user_systemd()
    if child is not None:
        attempt(lambda: (child.terminate(), child.wait(timeout=5)))
    else:
        attempt(unload_job)
    if content is None:
        attempt(lambda: path.unlink(missing_ok=True))
        if systemd:
            attempt(systemctl, 'daemon-reload')
        return 'the new service was removed', errors
    attempt(atomic, path, content.decode())
    if child is not None:
        return f'the previous job file (port {port}) was put back', errors
    if running:
        attempt(load_job, path)
        return f'the previous service on port {port} was restored and restarted', errors
    if systemd:
        attempt(systemctl, 'daemon-reload')
    return f'the previous service (port {port}) was put back, still stopped', errors


def failure_message(cause, outcome, errors, previous, path):
    message = f'{cause}; client configs were not changed'
    if not errors:
        return f'{message}; {outcome}'
    message += '. Rolling back also failed: ' + '; '.join(errors)
    if previous[0] is None:
        manual = (f'launchctl bootout {launchd_target()}' if sys.platform == 'darwin'
                  else f'systemctl --user disable --now {UNIT}')
        left = 'is still at ' + str(path) if path.exists() else 'was removed'
        return f'{message}. Its job file {left}; unload what is left with `{manual}`'
    again = f'graff mcp install --port {previous[2]}' if previous[2] else 'graff mcp install'
    return f'{message}. Restore the previous service with `{again}`'


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
    previous = snapshot(home)
    child = None
    try:
        child = service(home, binary, directory, args.port, token)
        for _ in range(30):
            if ready(url, token):
                break
            time.sleep(.2)
        else:
            raise ValueError(f'Service did not become ready on port {args.port}')
    except BaseException as error:
        # Interrupted or failed: nothing half-installed may stay loaded.
        outcome, errors = rollback(home, previous, child)
        if not isinstance(error, Exception):
            raise
        raise ValueError(failure_message(str(error), outcome, errors, previous, job_path(home))) from error
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
