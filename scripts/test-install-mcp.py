#!/usr/bin/env python3
import importlib.util
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
        with patch.object(installer.sys, 'platform', 'darwin'), patch.object(installer.subprocess, 'run') as run:
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

if __name__ == '__main__':
    unittest.main()
