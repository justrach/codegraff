"""Offline checks for trustworthy cross-model receipts and routing isolation."""
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import list_price
import measurement


class MeasurementTests(unittest.TestCase):
    def test_dollars_in_model_prose_are_not_usage(self):
        text = 'tool: revenue is $9999\n[usage] 2 api call(s) · 300 in (100 cached, 0 cache writes) + 20 out tokens · $0.0123\n'
        usage = measurement.graff_usage(text)
        self.assertEqual(usage['cost_usd'], .0123)
        self.assertEqual(usage['cached'], 100)
        self.assertEqual(measurement.graff_usage('answer costs $99'), {})

    def test_last_cumulative_footer_wins_and_missing_cost_is_unknown(self):
        text = '[usage] 1 api call(s) · 2 in (1 cached) + 3 out tokens · $0.001\n[usage] 2 api call(s) · 8 in (4 cached) + 9 out tokens'
        usage = measurement.graff_usage(text)
        self.assertEqual(usage['in'], 8)
        self.assertNotIn('cost_usd', usage)

    def test_incomplete_cost_is_not_zero_and_subscription_is_labelled(self):
        base = '[usage] 2 api call(s) · 8 in (4 cached) + 9 out tokens · $0.0000 · '
        self.assertIsNone(measurement.graff_usage(base + '2 call(s) on unpriced models')['cost_usd'])
        self.assertIsNone(measurement.graff_usage(base + '2 subscription call(s), flat-rate (not in $)')['cost_usd'])
        self.assertEqual(measurement.graff_usage(base + '2 subscription call(s), flat-rate (not in $)')['cost_kind'], 'metered-only-subscription-excluded')

    def test_multi_request_band_is_unavailable_not_mispriced(self):
        row = {'model': 'grok-4.6', 'tok_in': 250000, 'tok_calls': 2, 'tok_out': 100}
        list_price.attach(row)
        self.assertIsNone(row['list_usd'])
        self.assertEqual(row['list_price_kind'], 'unavailable-request-pricing')
        list_price.attach(dict(row, tok_calls=1))
        single = dict(row, tok_calls=1)
        list_price.attach(single)
        self.assertIsNotNone(single['list_usd'])

    def test_gateway_is_not_priced_at_direct_provider_rates(self):
        row = {'requested_provider': 'codegraff', 'model': 'grok-4.6', 'tok_in': 100, 'tok_calls': 1}
        list_price.attach(row)
        self.assertIsNone(row['list_usd'])

    def test_provider_environment_does_not_inherit_other_secrets_or_home(self):
        with tempfile.TemporaryDirectory() as temp:
            source = {'CODEGRAFF_API_KEY': 'fixture-only', 'OPENAI_API_KEY': 'wrong', 'AWS_SECRET_ACCESS_KEY': 'wrong', 'HOME': '/wrong', 'GRAFF_CODEX_URL': 'wrong', 'PATH': '/bin'}
            env = measurement.provider_environment('codegraff', temp, source)
            self.assertEqual(env['CODEGRAFF_API_KEY'], 'fixture-only')
            self.assertNotIn('OPENAI_API_KEY', env)
            self.assertNotIn('AWS_SECRET_ACCESS_KEY', env)
            self.assertNotIn('GRAFF_CODEX_URL', env)
            self.assertTrue(env['HOME'].startswith(temp))
            self.assertTrue(Path(env['GRAFF_MCP_CONFIG']).is_file())
        with self.assertRaises(ValueError):
            measurement.provider_environment('codegraff', '/unused', {})

    def test_codex_keeps_only_explicit_auth_directory_not_other_keys(self):
        with tempfile.TemporaryDirectory() as temp:
            auth = Path(temp) / 'auth'
            auth.mkdir()
            (auth / 'auth.json').write_text('{}')
            workspace = Path(temp) / 'workspace'
            workspace.mkdir()
            env = measurement.provider_environment('codex', str(workspace),
                  {'CODEX_HOME': str(auth), 'CODEGRAFF_API_KEY': 'wrong'}, model='gpt-6-astra')
            self.assertEqual(env['CODEX_HOME'], str(auth.resolve()))
            self.assertNotIn('CODEGRAFF_API_KEY', env)
            self.assertFalse((Path(env['HOME']) / 'auth.json').exists())
            with self.assertRaises(ValueError):
                measurement.provider_environment('codex', '/unused', {'CODEX_HOME': str(auth / 'missing')})

    def test_provider_selection_uses_same_production_saved_path_in_both_arms(self):
        with tempfile.TemporaryDirectory() as temp:
            env = measurement.provider_environment('codegraff', temp, {'CODEGRAFF_API_KEY': 'fixture'}, model='gpt-6-astra')
            self.assertEqual((Path(env['HOME']) / '.simple-harness-model').read_text(), 'codegraff\ngpt-6-astra\n')
        command = ['graff', '-p', 'hello', '--model', 'gpt-6-astra', '--yolo']
        self.assertEqual(measurement.provider_command(command), ['graff', '-p', 'hello', '--yolo'])

    def test_routing_requires_real_root_api_and_exact_model(self):
        with tempfile.TemporaryDirectory() as temp:
            traces = Path(temp) / '.graff/traces'
            traces.mkdir(parents=True)
            path = traces / 'trace.jsonl'
            path.write_text(json.dumps({'ev': 'api', 'agent': 'main', 'model': 'gpt-6-astra'}) + '\n')
            self.assertTrue(measurement.trace_routing(temp, 'codegraff', 'gpt-6-astra')['routing_ok'])
            self.assertFalse(measurement.trace_routing(temp, 'codegraff', 'wrong')['routing_ok'])
            path.write_text('{}\n')
            self.assertFalse(measurement.trace_routing(temp, 'codegraff', 'gpt-6-astra')['routing_ok'])

    def test_model_cannot_qualify_by_rewriting_visible_verifier(self):
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp) / 'test_public.py'
            path.write_text('raise AssertionError()')
            snap = measurement.verifier_snapshot(temp, {}, temp)
            self.assertTrue(measurement.verifiers_unchanged(snap))
            path.write_text('pass')
            self.assertFalse(measurement.verifiers_unchanged(snap))

    def test_untracked_source_is_in_snapshot_receipt(self):
        import subprocess
        with tempfile.TemporaryDirectory() as temp:
            subprocess.run(['git', 'init', '-q', temp], check=True)
            (Path(temp) / 'new.zig').write_text('pub const version = 1;')
            receipt = measurement.revision(temp)
            self.assertIn('new.zig', receipt['untracked_source_sha256'])
            self.assertEqual(len(receipt['untracked_source_sha256']['new.zig']), 64)

    def test_isolation_refuses_reusing_or_overwriting_a_run(self):
        with tempfile.TemporaryDirectory() as temp:
            target = str(Path(temp) / 'run')
            results, sandboxes = measurement.isolated_paths(target)
            self.assertEqual(Path(results).parent, Path(sandboxes).parent)
            with self.assertRaises(FileExistsError):
                measurement.isolated_paths(target)
            measurement.private_logs(sandboxes, 'fixture stdout', 'fixture stderr')
            self.assertEqual((Path(sandboxes) / '.eval-stdout.txt').stat().st_mode & 0o777, 0o600)


if __name__ == '__main__':
    unittest.main()
