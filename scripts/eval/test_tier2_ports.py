#!/usr/bin/env python3
"""Scripted evals route custom ports through Graff's local router config."""
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import Mock, patch

spec = importlib.util.spec_from_file_location('tier2_ports_runner', Path(__file__).parents[1] / 'eval-tier2.py')
tier2 = importlib.util.module_from_spec(spec)
spec.loader.exec_module(tier2)


class ScriptedPorts(unittest.TestCase):
    def capture_launch(self, requested, bound, *, provider=None, model=None, peer=False):
        launches = []

        def capture(argv, **kwargs):
            router = Path(kwargs['cwd']) / '.graff' / '.config.router'
            launches.append((argv, kwargs['env'], json.loads(router.read_text()) if router.exists() else None))
            return subprocess.CompletedProcess(argv, 0, '', '')

        server = Mock()
        server.start.return_value = bound
        server.requests = []
        process = Mock()
        process.poll.return_value = None
        case = {'prompt': 'local test'}
        if peer:
            case.update(live_peer=True, workspace_seed={'.graff/live/fixture.json': '{}'})
        with patch.dict(os.environ, {}, clear=True), \
                patch.object(tier2, 'ScriptedModel', return_value=server), \
                patch.object(tier2.subprocess, 'run', side_effect=capture), \
                patch.object(tier2.subprocess, 'Popen', return_value=process) as popen:
            run = tier2.execute(case, '/fake/graff', requested, provider, model)
        self.assertEqual(run.exit_code, 0)
        if provider:
            server.start.assert_not_called()
            server.stop.assert_not_called()
        else:
            server.start.assert_called_once_with(requested)
            server.stop.assert_called_once()
        if peer:
            self.assertEqual(popen.call_args.args[0], launches[0][0])
            process.kill.assert_called_once()
        return launches[0]

    def assert_route(self, launch, bound, model='lmstudio'):
        argv, env, router = launch
        self.assertEqual(argv[argv.index('--model') + 1], f'tier2/{model}')
        self.assertEqual(router, {
            'id': 'tier2', 'base_url': f'http://127.0.0.1:{bound}/v1',
            'env_key': 'TIER2_API_KEY', 'default_model': model,
        })
        self.assertEqual(env[router['env_key']], 'local')

    def test_nondefault_port_reaches_graff_router_and_model_selection(self):
        self.assert_route(self.capture_launch(12681, 12681), 12681)

    def test_os_assigned_port_uses_bound_port_not_requested_zero(self):
        self.assert_route(self.capture_launch(0, 49173), 49173)

    def test_custom_model_stays_on_the_custom_port(self):
        self.assert_route(self.capture_launch(12681, 12681, model='local-model'),
                          12681, 'local-model')

    def test_live_peer_uses_the_same_local_route(self):
        self.assert_route(self.capture_launch(12681, 12681, peer=True), 12681)

    def test_default_port_preserves_lmstudio_behavior(self):
        argv, env, router = self.capture_launch(1234, 1234)
        self.assertEqual(argv[-1], 'lmstudio')
        self.assertIsNone(router)
        self.assertNotIn('TIER2_API_KEY', env)

    def test_provider_mode_is_not_rerouted_and_never_starts_mock(self):
        argv, env, router = self.capture_launch(12681, 0, provider='explicit', model='chosen')
        self.assertEqual(argv[-3:], ['chosen', '--subagent-provider', 'explicit'])
        self.assertIsNone(router)
        self.assertNotIn('TIER2_API_KEY', env)

    def test_independent_process_reaches_mock_on_ephemeral_port(self):
        # Stand-in reads the same documented router metadata as Graff. This
        # exercises a real child process and local HTTP server, with no binary
        # build or external provider needed. Real-Graff checks remain tier 2.
        source = '''#!/usr/bin/env python3
import http.client, json, os, pathlib, sys
from urllib.parse import urlsplit
router = json.loads(pathlib.Path('.graff/.config.router').read_text())
assert sys.argv[sys.argv.index('--model') + 1] == 'tier2/lmstudio'
assert os.environ[router['env_key']] == 'local'
url = urlsplit(router['base_url'])
assert url.hostname == '127.0.0.1' and url.port not in (0, 1234)
conn = http.client.HTTPConnection(url.hostname, url.port, timeout=5)
conn.request('POST', url.path + '/chat/completions', json.dumps({'model': router['default_model']}))
response = conn.getresponse()
assert response.status == 200
reply = json.loads(response.read())['choices'][0]['message']['content']
print(json.dumps({'type': 'turn', 'text': reply}))
conn.close()
'''
        with tempfile.TemporaryDirectory() as temp, patch.dict(os.environ, {}, clear=True):
            executable = Path(temp) / 'graff-standin'
            executable.write_text(source)
            executable.chmod(0o700)
            run = tier2.execute({'prompt': 'local test', 'script': [{'text': 'custom-port-ok'}]},
                                str(executable), 0, None, None)
        self.assertEqual(run.exit_code, 0, run.stderr)
        self.assertEqual(run.requests, [{'model': 'lmstudio'}])
        self.assertEqual(run.final_text(), 'custom-port-ok')


if __name__ == '__main__':
    unittest.main()
