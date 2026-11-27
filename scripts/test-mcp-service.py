#!/usr/bin/env python3
"""`graff mcp service status|start|stop|uninstall` (#1928), driven by the
installer's recording launchctl/systemctl fakes. Nothing here runs a real
service manager or touches a real LaunchAgent."""
import contextlib
import importlib.util
import io
import json
import os
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('installer_tests', Path(__file__).with_name('test-install-mcp.py'))
installer_tests = importlib.util.module_from_spec(spec)
spec.loader.exec_module(installer_tests)
installer, FakeLaunchd, write_agent = installer_tests.installer, installer_tests.FakeLaunchd, installer_tests.write_agent


class ServiceControlTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.home = Path(self.tmp.name)
        self.agent = self.home / 'Library/LaunchAgents/dev.codegraff.mcp.plist'
        self.target = f'gui/{os.getuid()}/dev.codegraff.mcp'
        self.state = self.home / '.graff/mcp'

    def installed(self, port=7720):
        write_agent(self.home, port)
        self.state.mkdir(parents=True, exist_ok=True)
        (self.state / 'token').write_text('a' * 64 + '\n')
        (self.state / 'settings.json').write_text(json.dumps({'port': port, 'directory': str(self.home / 'proj')}))
        (self.state / 'clients.json').write_text(json.dumps({'.cursor/mcp.json': {}, '.claude.json': {}}))

    def run_cli(self, launchd, *words, answering=False, platform='darwin'):
        """Run the installer's `--service` entry point; returns (stdout, error or None)."""
        argv = ['install-mcp.py', '--binary', sys.executable, '--service', *words]
        out = io.StringIO()
        with patch.object(installer.sys, 'platform', platform), \
             patch.object(installer.sys, 'argv', argv), \
             patch.object(installer.Path, 'home', return_value=self.home), \
             patch.object(installer.shutil, 'which', return_value='/usr/bin/systemctl'), \
             patch.object(installer.subprocess, 'run', launchd), \
             patch.object(installer, 'ready', side_effect=lambda *_: answering() if callable(answering) else answering), \
             patch.object(installer.time, 'sleep'), contextlib.redirect_stdout(out):
            try:
                installer.main()
            except ValueError as error:
                return out.getvalue(), str(error)
        return out.getvalue(), None

    # status

    def test_status_not_installed(self):
        launchd = FakeLaunchd()
        out, error = self.run_cli(launchd, 'status')
        self.assertIsNone(error)
        self.assertEqual(out, 'MCP service: not installed\n  set it up with `graff mcp install`\n')
        self.assertEqual(launchd.commands, [])
        self.assertFalse((self.home / '.graff').exists(), 'status must not create anything')

    def test_status_running(self):
        self.installed()
        out, _ = self.run_cli(FakeLaunchd(loaded=True, pid=4242), 'status', answering=True)
        self.assertEqual(out, 'MCP service: running\n'
                              '  job:       ~/Library/LaunchAgents/dev.codegraff.mcp.plist\n'
                              '  manager:   launchd (loaded, pid 4242)\n'
                              '  url:       http://127.0.0.1:7720/mcp (answering)\n'
                              '  workspace: ~/proj\n')

    def test_status_stopped(self):
        self.installed(7731)
        out, _ = self.run_cli(FakeLaunchd(loaded=False), 'status')
        self.assertIn('MCP service: stopped\n', out)
        self.assertIn('launchd (not loaded)', out)
        self.assertIn('http://127.0.0.1:7731/mcp (not answering)', out)
        self.assertIn('start it with `graff mcp service start`', out)

    def test_status_loaded_but_not_answering(self):
        self.installed()
        out, _ = self.run_cli(FakeLaunchd(loaded=True), 'status')
        self.assertIn('MCP service: not answering\n', out)
        self.assertIn('service.log', out)

    def test_status_json(self):
        self.installed()
        out, _ = self.run_cli(FakeLaunchd(loaded=True, pid=7), 'status', '--json', answering=True)
        info = json.loads(out)
        self.assertEqual((info['state'], info['loaded'], info['pid'], info['port'], info['manager']),
                         ('running', True, 7, 7720, 'launchd'))
        self.assertEqual(info['job'], str(self.agent))
        self.agent.unlink()
        out, _ = self.run_cli(FakeLaunchd(), 'status', '--json')
        self.assertEqual((json.loads(out)['state'], json.loads(out)['loaded']), ('not installed', False))

    def test_status_names_a_foreign_job_without_touching_it(self):
        self.agent.parent.mkdir(parents=True)
        self.agent.write_bytes(plistlib.dumps({'Label': 'custom'}))
        launchd = FakeLaunchd()
        out, _ = self.run_cli(launchd, 'status')
        self.assertIn('MCP service: not managed by Codegraff', out)
        self.assertEqual(launchd.commands, [])

    # stop

    def test_stop_unloads_and_disables_but_keeps_the_job(self):
        self.installed()
        before = self.agent.read_bytes()
        launchd = FakeLaunchd(loaded=True)
        out, error = self.run_cli(launchd, 'stop', answering=True)
        self.assertIsNone(error)
        self.assertEqual(launchd.commands[-2:], [('launchctl', 'bootout', self.target),
                                                 ('launchctl', 'disable', self.target)])
        self.assertFalse(launchd.loaded)
        self.assertEqual(self.agent.read_bytes(), before, 'stop must not delete or rewrite the job')
        self.assertIn('MCP service stopped; it stays stopped, across logins too', out)
        self.assertIn('job file kept: ~/Library/LaunchAgents/dev.codegraff.mcp.plist', out)

    def test_stop_when_stopped_only_disables(self):
        self.installed()
        launchd = FakeLaunchd(loaded=False)
        out, error = self.run_cli(launchd, 'stop')
        self.assertIsNone(error)
        self.assertNotIn('bootout', launchd.verbs())
        self.assertEqual(launchd.commands[-1], ('launchctl', 'disable', self.target))
        self.assertIn('was already stopped', out)

    def test_stop_not_installed(self):
        launchd = FakeLaunchd()
        out, error = self.run_cli(launchd, 'stop')
        self.assertIsNone(error)
        self.assertEqual(out, 'MCP service is not installed; nothing to stop.\n')
        self.assertEqual(launchd.commands, [])

    def test_stop_quotes_launchd_and_changes_nothing_else(self):
        self.installed()
        launchd = FakeLaunchd(loaded=True, fail={('launchctl', 'bootout'): b'Boot-out failed: 5: Input/output error'})
        _, error = self.run_cli(launchd, 'stop', answering=True)
        self.assertEqual(error, f'launchctl bootout {self.target} failed: Boot-out failed: 5: Input/output error')
        self.assertNotIn('disable', launchd.verbs())
        self.assertTrue(self.agent.exists())

    # start

    def test_start_after_stop(self):
        self.installed()
        launchd = FakeLaunchd(loaded=False)
        out, error = self.run_cli(launchd, 'start', answering=lambda: launchd.loaded)
        self.assertIsNone(error)
        self.assertEqual(launchd.verbs()[-4:], ['enable', 'bootout', 'bootstrap', 'kickstart'])
        self.assertEqual(out, 'MCP service running at http://127.0.0.1:7720/mcp.\n')

    def test_start_when_running_changes_nothing(self):
        self.installed()
        launchd = FakeLaunchd(loaded=True)
        out, _ = self.run_cli(launchd, 'start', answering=True)
        self.assertEqual(launchd.verbs(), ['print'])
        self.assertIn('already running', out)

    def test_start_not_installed_fails(self):
        _, error = self.run_cli(FakeLaunchd(), 'start')
        self.assertIn('not installed; set it up with `graff mcp install`', error)

    def test_start_that_never_answers_says_so(self):
        self.installed()
        _, error = self.run_cli(FakeLaunchd(loaded=False), 'start')
        self.assertIn('started, but nothing answers at http://127.0.0.1:7720/mcp', error)

    def test_start_quotes_launchd(self):
        self.installed()
        launchd = FakeLaunchd(fail={('launchctl', 'bootstrap'): b'Bootstrap failed: 5: Input/output error'})
        _, error = self.run_cli(launchd, 'start')
        self.assertIn('Bootstrap failed: 5: Input/output error', error)

    # uninstall

    def test_uninstall_removes_the_job_and_keeps_token_settings_and_clients(self):
        self.installed()
        cursor = self.home / '.cursor/mcp.json'
        cursor.parent.mkdir()
        cursor.write_text('{"mcpServers": {"codegraff": {"url": "x"}}}')
        launchd = FakeLaunchd(loaded=True)
        out, error = self.run_cli(launchd, 'uninstall', answering=True)
        self.assertIsNone(error)
        self.assertEqual(launchd.commands[-1], ('launchctl', 'bootout', self.target))
        self.assertFalse(self.agent.exists())
        self.assertTrue((self.state / 'token').exists())
        self.assertTrue((self.state / 'settings.json').exists())
        self.assertEqual(cursor.read_text(), '{"mcpServers": {"codegraff": {"url": "x"}}}')
        self.assertIn('MCP service removed (~/Library/LaunchAgents/dev.codegraff.mcp.plist).', out)
        self.assertIn('client entries left in place: .claude.json, .cursor/mcp.json', out)

    def test_uninstall_is_idempotent(self):
        self.installed()
        launchd = FakeLaunchd(loaded=False)
        self.run_cli(launchd, 'uninstall')
        self.assertNotIn('bootout', launchd.verbs())
        self.assertFalse(self.agent.exists())
        again = FakeLaunchd()
        out, error = self.run_cli(again, 'uninstall')
        self.assertIsNone(error)
        self.assertEqual(out, 'MCP service is not installed; nothing to remove.\n')
        self.assertEqual(again.commands, [])

    def test_uninstall_keeps_the_job_when_unloading_fails(self):
        self.installed()
        launchd = FakeLaunchd(loaded=True, fail={('launchctl', 'bootout'): b'Boot-out failed: 150: Operation not permitted'})
        _, error = self.run_cli(launchd, 'uninstall', answering=True)
        self.assertEqual(error, f'launchctl bootout {self.target} failed: Boot-out failed: 150: Operation not permitted')
        self.assertTrue(self.agent.exists(), 'kept, so the same command can retry')

    def test_foreign_job_is_refused(self):
        self.agent.parent.mkdir(parents=True)
        original = plistlib.dumps({'Label': 'custom'})
        self.agent.write_bytes(original)
        for verb in ('stop', 'start', 'uninstall'):
            launchd = FakeLaunchd(loaded=True)
            _, error = self.run_cli(launchd, verb)
            self.assertIn('is not managed by Codegraff; left unchanged', error)
            self.assertEqual(launchd.commands, [])
        self.assertEqual(self.agent.read_bytes(), original)

    # Linux user systemd

    def systemd(self, active):
        commands = []
        def run(argv, **_kwargs):
            commands.append(tuple(argv))
            state = b'ActiveState=active\nMainPID=99\n' if active else b'ActiveState=inactive\nMainPID=0\n'
            return subprocess.CompletedProcess(argv, 0, state if 'show' in argv else b'', b'')
        run.commands = commands
        return run

    def linux_installed(self):
        unit = self.home / '.config/systemd/user/codegraff-mcp.service'
        unit.parent.mkdir(parents=True)
        unit.write_text(installer.systemd_unit(['/usr/bin/graff', 'mcp', 'serve', '--http', '--port', '7720'],
                                               self.home, 'a' * 64))
        self.state.mkdir(parents=True, exist_ok=True)
        (self.state / 'token').write_text('a' * 64)
        return unit

    def test_linux_status_stop_and_uninstall(self):
        unit = self.linux_installed()
        out, _ = self.run_cli(self.systemd(True), 'status', answering=True, platform='linux')
        self.assertIn('manager:   systemd (loaded, pid 99)', out)
        self.assertIn('http://127.0.0.1:7720/mcp (answering)', out)
        stop = self.systemd(True)
        self.run_cli(stop, 'stop', answering=True, platform='linux')
        self.assertIn(('systemctl', '--user', 'disable', '--now', 'codegraff-mcp.service'), stop.commands)
        self.assertTrue(unit.exists())
        remove = self.systemd(False)
        self.run_cli(remove, 'uninstall', platform='linux')
        self.assertEqual(remove.commands[-1], ('systemctl', '--user', 'daemon-reload'))
        self.assertFalse(unit.exists())


class InstallAfterStopTests(unittest.TestCase):
    def test_install_re_enables_a_stopped_job(self):
        with tempfile.TemporaryDirectory() as tmp:
            launchd = FakeLaunchd()
            with patch.object(installer.sys, 'platform', 'darwin'), patch.object(installer.subprocess, 'run', launchd):
                installer.service(Path(tmp), Path(sys.executable), Path(tmp), 7720, 'a' * 64)
            self.assertEqual(launchd.verbs()[0], 'enable', 'bootstrap of a disabled job fails')


if __name__ == '__main__':
    unittest.main()
