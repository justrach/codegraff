#!/usr/bin/env python3
import contextlib
import importlib.util
import io
import json
import os
from pathlib import Path
import plistlib
import subprocess
import tempfile
import threading
import time
import sys
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('installer', Path(__file__).with_name('install-mcp.py'))
installer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(installer)

class InstallTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.home = Path(self.tmp.name)
        self.url = 'http://127.0.0.1:7720/mcp'
        self.token = 'a' * 64

    def test_additive_idempotent_clients(self):
        cursor = self.home / '.cursor/mcp.json'
        cursor.parent.mkdir()
        cursor.write_text(json.dumps({'mcpServers': {'other': {'env': {'KEY': 'retained'}}}, 'setting': 1}))
        codex = self.home / '.codex/config.toml'
        codex.parent.mkdir()
        codex.write_text('# keep comment\nmodel = "local"\n')
        installer.register(self.home, self.url, self.token)
        before = (cursor.read_bytes(), codex.read_bytes())
        installer.register(self.home, self.url, self.token)
        self.assertEqual(before, (cursor.read_bytes(), codex.read_bytes()))
        self.assertEqual(json.loads(cursor.read_text())['mcpServers']['other']['env']['KEY'], 'retained')
        self.assertTrue(codex.read_text().startswith('# keep comment'))
        self.assertEqual(cursor.stat().st_mode & 0o777, 0o600)

    def test_owned_entries_refresh_but_user_edits_survive(self):
        cursor = self.home / '.cursor/mcp.json'
        cursor.parent.mkdir()
        codex = self.home / '.codex/config.toml'
        codex.parent.mkdir()
        installer.register(self.home, self.url, self.token)
        new_url = 'http://127.0.0.1:7721/mcp'
        installer.register(self.home, new_url, self.token)
        self.assertEqual(json.loads(cursor.read_text())['mcpServers']['codegraff']['url'], new_url)
        if sys.version_info >= (3, 11):
            self.assertIn(new_url, codex.read_text())
        data = json.loads(cursor.read_text())
        data['mcpServers']['codegraff']['custom'] = True
        cursor.write_text(json.dumps(data))
        before = cursor.read_bytes()
        installer.register(self.home, self.url, self.token)
        self.assertEqual(cursor.read_bytes(), before)
        if sys.version_info >= (3, 11):
            self.assertIn(self.url, codex.read_text())

    def test_malformed_config_unchanged(self):
        path = self.home / '.cursor/mcp.json'
        path.parent.mkdir()
        path.write_text('{ broken')
        result = installer.register(self.home, self.url, self.token)
        self.assertIn('skipped', result[0][1])
        self.assertEqual(path.read_text(), '{ broken')

    def test_custom_codegraff_preserved(self):
        path = self.home / '.claude.json'
        source = '{"mcpServers":{"codegraff":{"command":"custom"}}}'
        path.write_text(source)
        installer.register(self.home, self.url, self.token)
        self.assertEqual(path.read_text(), source)

    def test_absent_clients_not_created(self):
        self.assertEqual(installer.register(self.home, self.url, self.token), [])
        self.assertEqual(list(self.home.iterdir()), [])

    def test_launch_agent_private_and_quoted(self):
        ok = subprocess.CompletedProcess([], 0, b'', b'')
        with patch.object(installer.sys, 'platform', 'darwin'), \
             patch.object(installer.subprocess, 'run', return_value=ok) as run:
            installer.service(self.home, Path('/Applications/A B.app/graff'), self.home, 7720, self.token)
        path = self.home / 'Library/LaunchAgents/dev.codegraff.mcp.plist'
        data = plistlib.loads(path.read_bytes())
        self.assertEqual(data['ProgramArguments'][0], '/Applications/A B.app/graff')
        self.assertEqual(data['EnvironmentVariables']['GRAFF_MCP_TOKEN'], self.token)
        self.assertEqual(path.stat().st_mode & 0o777, 0o600)
        commands = [tuple(call.args[0]) for call in run.call_args_list]
        domain = f'gui/{os.getuid()}/dev.codegraff.mcp'
        self.assertEqual(commands, [
            ('launchctl', 'bootout', domain),
            ('launchctl', 'bootstrap', f'gui/{os.getuid()}', str(path)),
            ('launchctl', 'kickstart', '-k', domain),
        ])

    def test_unmanaged_service_preserved(self):
        path = self.home / 'Library/LaunchAgents/dev.codegraff.mcp.plist'
        path.parent.mkdir(parents=True)
        original = plistlib.dumps({'Label': 'custom'})
        path.write_bytes(original)
        with patch.object(installer.sys, 'platform', 'darwin'), patch.object(installer.subprocess, 'run') as run:
            with self.assertRaises(ValueError):
                installer.service(self.home, Path('/bin/echo'), self.home, 7720, self.token)
            run.assert_not_called()
        self.assertEqual(path.read_bytes(), original)

    def _hold_lock(self, lock_path):
        holder = subprocess.Popen(
            [sys.executable, '-c',
             'import fcntl, sys, time\n'
             'f = open(sys.argv[1], "a")\n'
             'fcntl.flock(f.fileno(), fcntl.LOCK_EX)\n'
             'sys.stdout.write("h")\n'
             'sys.stdout.flush()\n'
             'time.sleep(30)\n', str(lock_path)],
            stdout=subprocess.PIPE,
        )
        self.addCleanup(holder.kill)
        self.assertEqual(holder.stdout.read(1), b'h')
        return holder

    def test_lock_waits_for_holder(self):
        lock_path = self.home / 'install.lock'
        holder = self._hold_lock(lock_path)
        got = []
        def waiter():
            handle = installer.acquire_install_lock(lock_path, timeout=2)
            got.append(True)
            handle.close()
        thread = threading.Thread(target=waiter)
        thread.start()
        time.sleep(0.15)
        self.assertEqual(got, [])
        holder.kill()
        holder.wait()
        thread.join(2)
        self.assertFalse(thread.is_alive())
        self.assertEqual(got, [True])

    def test_lock_timeout_is_not_blocking_io(self):
        lock_path = self.home / 'install.lock'
        self._hold_lock(lock_path)
        with self.assertRaises(ValueError) as ctx:
            installer.acquire_install_lock(lock_path, timeout=0.25)
        self.assertIn('already running', str(ctx.exception))

    def test_run_managed_retries_blocking_io(self):
        calls = {'n': 0}
        def fake(argv, **_kwargs):
            calls['n'] += 1
            if calls['n'] < 3:
                raise BlockingIOError(35, 'Resource temporarily unavailable')
            return subprocess.CompletedProcess(argv, 0)
        with patch.object(installer.subprocess, 'run', fake):
            installer.run_managed(['launchctl', 'bootstrap', 'x'])
        self.assertEqual(calls['n'], 3)

    def test_linux_without_user_systemd_starts_detached(self):
        with patch.object(installer.sys, 'platform', 'linux'), \
             patch.object(installer.shutil, 'which', return_value='/usr/bin/systemctl'), \
             patch.object(installer, 'linux_user_systemd', return_value=False), \
             patch.object(installer.subprocess, 'Popen') as popen:
            installer.service(self.home, Path('/usr/bin/graff'), self.home, 7720, self.token)
        popen.assert_called_once()
        unit = self.home / '.config/systemd/user/codegraff-mcp.service'
        self.assertIn('Codegraff managed MCP service', unit.read_text())
        self.assertIn('mcp', unit.read_text())

    def test_systemd_unit_working_directory_is_a_literal_path(self):
        directory = Path('/home/user/my 100% $proj')
        unit = installer.systemd_unit(['/usr/bin/graff', 'mcp', 'serve'], directory, self.token)
        line = next(l for l in unit.splitlines() if l.startswith('WorkingDirectory='))
        # Unquoted (systemd takes the rest of the line as one path); only % escaped.
        self.assertEqual(line, 'WorkingDirectory=/home/user/my 100%% $proj')
        self.assertIn('ExecStart="/usr/bin/graff" "mcp" "serve"', unit)
        with self.assertRaises(ValueError):
            installer.systemd_unit(['graff'], 'relative/dir', self.token)

    @unittest.skipUnless(sys.platform.startswith('linux') and installer.shutil.which('systemd-analyze'),
                         'needs systemd-analyze')
    def test_systemd_accepts_the_unit(self):
        workspace = self.home / 'my 100% proj'
        workspace.mkdir()
        unit = self.home / 'codegraff-mcp.service'
        unit.write_text(installer.systemd_unit(['/bin/true'], workspace, self.token))
        result = subprocess.run(['systemd-analyze', '--user', 'verify', str(unit)],
                                capture_output=True, text=True)
        self.assertNotIn('not absolute', result.stderr)
        self.assertNotIn('WorkingDirectory', result.stderr)

    def test_systemctl_failure_carries_its_stderr(self):
        failed = subprocess.CompletedProcess(['systemctl'], 1, b'', b'Failed to enable unit: Unit file is masked.')
        with patch.object(installer, 'run_managed', return_value=failed):
            with self.assertRaises(ValueError) as caught:
                installer.systemctl('enable', '--now', 'codegraff-mcp.service')
        self.assertIn('Unit file is masked', str(caught.exception))


class ReadinessFailureRollbackTests(unittest.TestCase):
    """#1929: a replacement service that never becomes ready must not stay
    installed, and a failed port change puts the previous job back."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.home = Path(self.tmp.name)
        self.agent = self.home / 'Library/LaunchAgents/dev.codegraff.mcp.plist'
        self.settings = self.home / '.graff/mcp/settings.json'
        self.binary = Path(sys.executable).resolve()
        self.domain = f'gui/{os.getuid()}'
        self.commands = []

    def _install_with_failing_readiness(self, port):
        def record(argv, **_kwargs):
            self.commands.append(tuple(argv))
            return subprocess.CompletedProcess(argv, 0, b'', b'')
        argv = ['install-mcp.py', '--binary', str(self.binary), '--directory', str(self.home), '--port', str(port)]
        with patch.object(installer.sys, 'platform', 'darwin'), \
             patch.object(installer.sys, 'argv', argv), \
             patch.object(installer.Path, 'home', return_value=self.home), \
             patch.dict(installer.os.environ, {'GRAFF_NO_MCP': ''}), \
             patch.object(installer.subprocess, 'run', record), \
             patch.object(installer, 'ready', return_value=False), \
             patch.object(installer.time, 'sleep'):
            with self.assertRaises(ValueError) as caught:
                installer.main()
        self.assertIn('did not become ready', str(caught.exception))

    def _bootstraps(self):
        return [c for c in self.commands if c[:2] == ('launchctl', 'bootstrap')]

    def test_1929_failed_first_install_removes_the_new_job(self):
        self._install_with_failing_readiness(7731)
        self.assertFalse(self.settings.exists())
        last_bootstrap = max(i for i, c in enumerate(self.commands) if c[:2] == ('launchctl', 'bootstrap'))
        self.assertIn(('launchctl', 'bootout', self.domain + '/dev.codegraff.mcp'),
                      self.commands[last_bootstrap + 1:], 'replacement job was never unloaded')
        self.assertFalse(self.agent.exists(), 'replacement LaunchAgent left installed after readiness failure')

    def test_1929_failed_reconfigure_restores_the_previous_job(self):
        self.agent.parent.mkdir(parents=True)
        self.agent.write_bytes(plistlib.dumps({
            'Label': 'dev.codegraff.mcp', 'CodegraffManaged': 1, 'RunAtLoad': True, 'KeepAlive': True,
            'ProgramArguments': [str(self.binary), 'mcp', 'serve', '--http', '--port', '7730']}))
        self.settings.parent.mkdir(parents=True)
        self.settings.write_text(json.dumps({'port': 7730, 'directory': str(self.home)}))
        self._install_with_failing_readiness(7731)
        self.assertEqual(json.loads(self.settings.read_text())['port'], 7730)
        self.assertEqual(plistlib.loads(self.agent.read_bytes())['ProgramArguments'][-1], '7730',
                         'LaunchAgent still points at the port that failed readiness')
        self.assertGreaterEqual(len(self._bootstraps()), 2, 'previous job was never restarted')


class FakeLaunchd:
    """A recording launchctl: `print` answers from the loaded flag, and any
    command whose words start with a key of `fail` exits 5 with that stderr."""

    def __init__(self, loaded=False, pid=4242, fail=None):
        self.loaded, self.pid, self.fail, self.commands = loaded, pid, dict(fail or {}), []

    def __call__(self, argv, **_kwargs):
        argv = tuple(argv)
        self.commands.append(argv)
        for prefix, stderr in self.fail.items():
            if argv[:len(prefix)] == prefix:
                return subprocess.CompletedProcess(argv, 5, b'', stderr)
        verb = argv[1] if len(argv) > 1 else ''
        if verb == 'print':
            if not self.loaded:
                return subprocess.CompletedProcess(argv, 113, b'', b'Could not find service')
            return subprocess.CompletedProcess(argv, 0, f'state = running\n\tpid = {self.pid}\n'.encode(), b'')
        if verb == 'bootstrap':
            self.loaded = True
        elif verb == 'bootout':
            was, self.loaded = self.loaded, False
            if not was:
                return subprocess.CompletedProcess(argv, 3, b'', b'Boot-out failed: 3: No such process')
        return subprocess.CompletedProcess(argv, 0, b'', b'')

    def verbs(self):
        return [c[1] for c in self.commands if c[0] == 'launchctl']


def write_agent(home, port, binary=sys.executable):
    agent = home / 'Library/LaunchAgents/dev.codegraff.mcp.plist'
    agent.parent.mkdir(parents=True, exist_ok=True)
    agent.write_bytes(plistlib.dumps({
        'Label': 'dev.codegraff.mcp', 'CodegraffManaged': 1, 'RunAtLoad': True, 'KeepAlive': True,
        'ProgramArguments': [str(binary), 'mcp', 'serve', '--http', '--port', str(port)]}))
    return agent


class TransactionalInstallTests(unittest.TestCase):
    """#1929: the error says what was rolled back, rollback failures are
    reported alongside the cause, and a ready service is installed as before."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.home = Path(self.tmp.name)
        self.agent = self.home / 'Library/LaunchAgents/dev.codegraff.mcp.plist'
        self.settings = self.home / '.graff/mcp/settings.json'
        self.target = f'gui/{os.getuid()}/dev.codegraff.mcp'

    def install(self, launchd, port, is_ready=False):
        argv = ['install-mcp.py', '--binary', sys.executable, '--directory', str(self.home), '--port', str(port)]
        with patch.object(installer.sys, 'platform', 'darwin'), \
             patch.object(installer.sys, 'argv', argv), \
             patch.object(installer.Path, 'home', return_value=self.home), \
             patch.dict(installer.os.environ, {'GRAFF_NO_MCP': ''}), \
             patch.object(installer.subprocess, 'run', launchd), \
             patch.object(installer, 'ready', return_value=is_ready), \
             patch.object(installer.time, 'sleep'):
            if is_ready:
                with contextlib.redirect_stdout(io.StringIO()):
                    installer.main()
                return None
            with self.assertRaises(ValueError) as caught:
                installer.main()
            return str(caught.exception)

    def reconfigure_from(self, port, launchd):
        write_agent(self.home, port)
        self.settings.parent.mkdir(parents=True, exist_ok=True)
        self.settings.write_text(json.dumps({'port': port, 'directory': str(self.home)}))
        return self.agent.read_bytes(), self.settings.read_bytes()

    def test_failed_first_install_says_the_new_job_was_removed(self):
        launchd = FakeLaunchd()
        message = self.install(launchd, 7731)
        self.assertIn('did not become ready on port 7731', message)
        self.assertIn('the new service was removed', message)
        self.assertFalse(launchd.loaded)
        self.assertFalse(self.agent.exists())
        self.assertFalse(self.settings.exists())

    def test_failed_reconfigure_restores_the_running_job_byte_for_byte(self):
        launchd = FakeLaunchd(loaded=True)
        agent, settings = self.reconfigure_from(7730, launchd)
        message = self.install(launchd, 7731)
        self.assertIn('previous service on port 7730 was restored and restarted', message)
        self.assertEqual(self.agent.read_bytes(), agent)
        self.assertEqual(self.settings.read_bytes(), settings)
        self.assertTrue(launchd.loaded)
        self.assertEqual(launchd.commands[-1], ('launchctl', 'kickstart', '-k', self.target))

    def test_failed_reconfigure_of_a_stopped_job_leaves_it_stopped(self):
        launchd = FakeLaunchd(loaded=False)
        agent, _ = self.reconfigure_from(7730, launchd)
        message = self.install(launchd, 7731)
        self.assertIn('put back, still stopped', message)
        self.assertEqual(self.agent.read_bytes(), agent)
        self.assertFalse(launchd.loaded)

    def test_a_failed_bootstrap_is_rolled_back_and_quoted(self):
        launchd = FakeLaunchd(loaded=True, fail={('launchctl', 'bootstrap'): b'Bootstrap failed: 5: Input/output error'})
        agent, settings = self.reconfigure_from(7730, launchd)
        message = self.install(launchd, 7731)
        self.assertIn('Bootstrap failed: 5: Input/output error', message)
        self.assertIn('client configs were not changed', message)
        # Restoring needs a bootstrap too, which fails the same way: both are reported.
        self.assertIn('Rolling back also failed', message)
        self.assertIn('graff mcp install --port 7730', message)
        self.assertEqual(self.agent.read_bytes(), agent)
        self.assertEqual(self.settings.read_bytes(), settings)

    def test_failed_first_install_whose_unload_fails_reports_both(self):
        launchd = FakeLaunchd(fail={('launchctl', 'bootout'): b'Boot-out failed: 150: Operation not permitted'})
        message = self.install(launchd, 7731)
        self.assertIn('did not become ready', message)
        self.assertIn('Operation not permitted', message)
        self.assertIn(f'launchctl bootout {self.target}', message)
        self.assertIn('job file was removed', message)
        self.assertFalse(self.agent.exists(), 'a job left on disk would start again at login')

    def test_ready_service_installs_as_before(self):
        cursor = self.home / '.cursor/mcp.json'
        cursor.parent.mkdir()
        launchd = FakeLaunchd()
        self.install(launchd, 7731, is_ready=True)
        self.assertEqual(launchd.verbs(), ['bootout', 'bootstrap', 'kickstart'])
        self.assertTrue(launchd.loaded)
        self.assertEqual(json.loads(self.settings.read_text())['port'], 7731)
        self.assertEqual(plistlib.loads(self.agent.read_bytes())['ProgramArguments'][-1], '7731')
        self.assertIn('127.0.0.1:7731', cursor.read_text())

    def test_foreign_job_is_refused_before_anything_changes(self):
        self.agent.parent.mkdir(parents=True)
        original = plistlib.dumps({'Label': 'custom'})
        self.agent.write_bytes(original)
        launchd = FakeLaunchd()
        message = self.install(launchd, 7731)
        self.assertIn('not managed by Codegraff', message)
        self.assertEqual(launchd.commands, [])
        self.assertEqual(self.agent.read_bytes(), original)

    def test_linux_failed_first_install_disables_and_removes_the_unit(self):
        commands = []
        def systemd(argv, **_kwargs):
            commands.append(tuple(argv))
            return subprocess.CompletedProcess(argv, 0, b'ActiveState=inactive\nMainPID=0\n', b'')
        argv = ['install-mcp.py', '--binary', sys.executable, '--directory', str(self.home), '--port', '7731']
        with patch.object(installer.sys, 'platform', 'linux'), \
             patch.object(installer.sys, 'argv', argv), \
             patch.object(installer.Path, 'home', return_value=self.home), \
             patch.dict(installer.os.environ, {'GRAFF_NO_MCP': ''}), \
             patch.object(installer.shutil, 'which', return_value='/usr/bin/systemctl'), \
             patch.object(installer.subprocess, 'run', systemd), \
             patch.object(installer, 'ready', return_value=False), \
             patch.object(installer.time, 'sleep'):
            with self.assertRaises(ValueError) as caught:
                installer.main()
        self.assertIn('the new service was removed', str(caught.exception))
        unit = 'codegraff-mcp.service'
        restart = commands.index(('systemctl', '--user', 'restart', unit))
        self.assertIn(('systemctl', '--user', 'disable', '--now', unit), commands[restart:])
        self.assertEqual(commands[-1], ('systemctl', '--user', 'daemon-reload'))
        self.assertFalse((self.home / '.config/systemd/user' / unit).exists())


if __name__ == '__main__':
    unittest.main()
