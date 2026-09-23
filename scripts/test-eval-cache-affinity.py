#!/usr/bin/env python3
"""Offline measurement guards; fake executables never contact a provider."""
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

SCRIPT = Path(__file__).with_name('eval-cache-affinity.py')
spec = importlib.util.spec_from_file_location('cache_probe', SCRIPT)
probe = importlib.util.module_from_spec(spec)
spec.loader.exec_module(probe)
FOOTER = '[usage] 1 api call(s) · 3000 in (2000 cached, 100 cache writes) + 5 out tokens · $0.0100'
ROWS = [{'ev': 'api', 'agent': 'main', 'provider': 'codegraff', 'model': 'fixture'}]


class ProbeTests(unittest.TestCase):
    def test_cache_is_subset_and_final_footer_wins(self):
        result = probe.validate('CACHE_OK\n', '[usage] malformed\n' + FOOTER, ROWS, 'fixture', 0, False)
        self.assertTrue(result['valid'])
        self.assertEqual(result['usage']['input_tokens'], 3000)
        self.assertEqual(result['usage']['ordinary_input_tokens'], 900)
        self.assertEqual(result['raw_final_usage'], FOOTER)

    def test_missing_or_invalid_evidence_does_not_become_zero(self):
        for stderr, rows in [('', ROWS), (FOOTER, []),
                             (FOOTER.replace('3000 in', '1000 in'), ROWS),
                             (FOOTER, [{**ROWS[0], 'provider': 'other'}])]:
            result = probe.validate('CACHE_OK', stderr, rows, 'fixture', 0, False)
            self.assertFalse(result['valid'])
        self.assertIsNone(probe.validate('CACHE_OK', '', ROWS, 'fixture', 0, False)['usage'])
        result = probe.validate('CACHE_OK', FOOTER + ' · 1 call(s) on unpriced models', ROWS, 'fixture', 0, False)
        self.assertIsNone(result['usage']['cost_usd'])
        legacy = probe.validate('CACHE_OK', FOOTER.replace(', 100 cache writes', ''), ROWS, 'fixture', 0, False)
        self.assertIsNone(legacy['usage']['cache_write_tokens'])
        self.assertIsNone(legacy['usage']['ordinary_input_tokens'])
        self.assertFalse(probe.validate('CACHE_OK extra', FOOTER, ROWS, 'fixture', 0, False)['valid'])
        self.assertFalse(probe.validate('CACHE_OK', FOOTER, ROWS, 'fixture', 1, False)['valid'])

    def test_fake_processes_use_real_worktrees_private_homes_and_counterbalance(self):
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            for arm in ('before', 'after'):
                binary = root / arm
                binary.write_text(f'''#!{sys.executable}
import json, os
from pathlib import Path
assert 'OPENAI_API_KEY' not in os.environ
assert 'CODEGRAFF_API_KEY' in os.environ
assert '--model' not in __import__('sys').argv
provider, model = (Path.home()/'.simple-harness-model').read_text().splitlines()
p = Path('.graff/traces'); p.mkdir(parents=True)
(p/'fixture.jsonl').write_text(json.dumps({{'ev':'api','agent':'main','provider':provider,'model':model}})+'\\n')
print('CACHE_OK')
print({FOOTER!r}, file=__import__('sys').stderr)
# {arm}
''')
                binary.chmod(0o700)
            out = root / 'result'
            env = dict(os.environ, CODEGRAFF_API_KEY='offline-fixture-only', OPENAI_API_KEY='must-not-inherit')
            p = subprocess.run([sys.executable, str(SCRIPT), '--before', str(root/'before'),
                                '--after', str(root/'after'), '--model', 'fixture', '--repeats', '2',
                                '--out', str(out)], env=env, capture_output=True, text=True, timeout=30)
            self.assertEqual(p.returncode, 0, p.stderr + p.stdout)
            pairs = json.loads((out/'pairs.json').read_text())
            self.assertEqual(pairs[0]['order'], ['before', 'after'])
            self.assertEqual(pairs[1]['order'], ['after', 'before'])
            self.assertEqual(json.loads((out/'summary.json').read_text())['fixture']['valid_pairs'], 2)
            for pair in pairs:
                self.assertEqual(pair['before']['linked']['prompt_sha256'], pair['after']['linked']['prompt_sha256'])
            # NTFS ACLs, not POSIX mode bits, govern access on Windows.
            if os.name != 'nt':
                self.assertEqual(out.stat().st_mode & 0o777, 0o700)
                for path in out.rglob('*'):
                    self.assertEqual(path.stat().st_mode & 0o077, 0, str(path))


if __name__ == '__main__':
    unittest.main()
