#!/usr/bin/env python3
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import tempfile
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
        self.assertEqual(run.call_count, 2)

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

if __name__ == '__main__':
    unittest.main()
