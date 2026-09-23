"""Offline checks for trustworthy cross-model receipts and routing isolation."""
import json
import contextlib
import io
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import list_price
import measurement
import request_capture
import report


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

    def test_missing_usage_preserves_subtotals_without_claiming_complete_totals(self):
        footer = ('[usage] 3 api call(s) · 80 in (40 cached, 5 cache writes) + 9 out tokens · $0.001234'
                  ' · totals incomplete: 1 call(s) missing usage (tokens and cost unknown)')
        usage = measurement.graff_usage(footer)
        self.assertEqual(usage['calls'], 3)
        self.assertEqual(usage['missing_usage_calls'], 1)
        self.assertFalse(usage['usage_complete'])
        for key, subtotal in [('in', 80), ('cached', 40), ('writes', 5), ('out', 9), ('cost_usd', .001234)]:
            self.assertIsNone(usage[key])
            self.assertEqual(usage['known_' + key], subtotal)
        self.assertEqual(usage['cost_kind'], 'incomplete-missing-usage')
        # Exercise the runner's actual receipt prefix and downstream pricing.
        row = dict(model='grok-4.6', requested_provider='xai', harness='graff-dev',
                   **{'tok_' + k: v for k, v in usage.items()})
        list_price.attach(row)
        for key in ('ordinary', 'cached', 'out', 'prompt', 'tokens', 'token_usd', 'tool_usd', 'usd', 'high_band'):
            self.assertIsNone(row['list_' + key])
        self.assertEqual(row['list_price_kind'], 'unavailable-missing-usage')
        self.assertEqual(row['tok_known_in'], 80)

    def test_all_missing_usage_zero_subtotals_and_subscription_are_unknown(self):
        base = '[usage] 2 api call(s) · 0 in (0 cached) + 0 out tokens · $0.000000 · '
        missing = 'totals incomplete: 2 call(s) missing usage (tokens and cost unknown)'
        for classification in ('', '2 subscription call(s), flat-rate (not in $) · ',
                               '2 call(s) on unpriced models · '):
            with self.subTest(classification=classification):
                usage = measurement.graff_usage(base + classification + missing)
                self.assertEqual(usage['known_in'], 0)
                self.assertEqual(usage['known_cost_usd'], 0)
                self.assertIsNone(usage['in'])
                self.assertIsNone(usage['cost_usd'])
                self.assertEqual(usage['missing_usage_calls'], 2)
                if classification.startswith('2 subscription'):
                    self.assertEqual(usage['sub_calls'], 2)
                elif classification:
                    self.assertEqual(usage['unpriced_calls'], 2)

    def test_incomplete_receipt_reporting_never_turns_missing_tokens_into_zero(self):
        usage = measurement.graff_usage(
            '[usage] 2 api call(s) · 80 in (40 cached) + 9 out tokens · $0.001234'
            ' · totals incomplete: 1 call(s) missing usage (tokens and cost unknown)')
        row = dict(harness='graff-dev', model='grok-4.6', outcome_ok=True,
                   **{'tok_' + k: v for k, v in usage.items()})
        list_price.attach(row)
        complete = dict(harness='graff-dev', outcome_ok=True, tok_in=10, tok_cached=2,
                        tok_out=3, tok_calls=1, tok_cost_usd=.01, list_usd=.02)
        for suite in (None, 'live'):
            grouped = report.bucket([row, complete], suite=suite)
            bucket = grouped['graff-dev']
            self.assertIsNone(bucket['tin'])
            self.assertIsNone(bucket['usd'])
            self.assertEqual(bucket['missing_usage_calls'], 1)
            self.assertEqual(bucket['known_tin'], 50)
            self.assertEqual(bucket['known_tcached'], 42)
            self.assertEqual(bucket['known_tout'], 12)
            # Only the complete row contributes its selected list-price estimate.
            # The incomplete actual-route subtotal stays in the receipt.
            self.assertEqual(bucket['known_usd'], .02)
            self.assertEqual(row['tok_known_cost_usd'], .001234)
            output = io.StringIO()
            with contextlib.redirect_stdout(output):
                report.print_table('fixture', grouped, suite=suite)
            self.assertIn('unknown', output.getvalue())
            self.assertIn('totals incomplete: 1 call(s)', output.getvalue())
        self.assertIn('in=unknown', report.line(row))
        self.assertIn('totals incomplete', report.line(row))

    def test_complete_legacy_footer_receipt_stays_unchanged(self):
        footer = '[usage] 1 api call(s) · 80 in (40 cached, 5 cache writes) + 9 out tokens · $0.001234'
        self.assertEqual(measurement.graff_usage(footer),
                         {'calls': 1, 'in': 80, 'cached': 40, 'writes': 5, 'out': 9,
                          'cost_usd': .001234, 'cost_kind': 'harness-reported'})
        missing = footer + ' · totals incomplete: 1 call(s) missing usage (tokens and cost unknown)'
        self.assertIsNone(measurement.graff_usage(footer + '\n' + missing)['in'])
        self.assertEqual(measurement.graff_usage(missing + '\n' + footer), measurement.graff_usage(footer))

    def test_released_known_subtotal_prefix_and_failed_attempt_tail(self):
        for calls, ordinary, dollars in [(0, 0, 0), (1, 80, .001234)]:
            with self.subTest(calls=calls):
                footer = (f'[usage] known subtotal: {calls} api call(s) · {ordinary} in (0 cached) + 0 out tokens · ${dollars:.6f}'
                          ' · totals incomplete: 2 failed request attempt(s) without usage (tokens and cost unknown)')
                usage = measurement.graff_usage(footer)
                self.assertEqual(usage['calls'], calls)
                self.assertEqual(usage['unreported_failed_attempts'], 2)
                self.assertFalse(usage['usage_complete'])
                self.assertEqual(usage['known_in'], ordinary)
                self.assertEqual(usage['known_cost_usd'], dollars)
                for key in ('in', 'cached', 'writes', 'out', 'cost_usd'):
                    self.assertIsNone(usage[key])
                row = dict(model='grok-4.6', requested_provider='xai', harness='graff-dev',
                           **{'tok_' + k: v for k, v in usage.items()})
                list_price.attach(row)
                self.assertIsNone(row['list_usd'])
                self.assertEqual(row['list_price_kind'], 'unavailable-missing-usage')
                self.assertIsNone(report.bucket([row])['graff-dev']['usd'])

    def test_missing_and_failed_usage_counters_remain_distinct(self):
        base = '[usage] known subtotal: 3 api call(s) · 80 in (40 cached, 5 cache writes) + 9 out tokens · $0.001234'
        for extra in ('', ' · 2 subscription call(s), flat-rate (not in $)',
                      ' · 2 call(s) on unpriced models'):
            with self.subTest(extra=extra):
                usage = measurement.graff_usage(base + extra +
                    ' · totals incomplete: 1 call(s) missing usage (tokens and cost unknown)' +
                    ' · totals incomplete: 2 failed request attempt(s) without usage (tokens and cost unknown)')
                self.assertEqual(usage['missing_usage_calls'], 1)
                self.assertEqual(usage['unreported_failed_attempts'], 2)
                self.assertEqual(usage['calls'], 3)
                self.assertEqual(usage['known_cached'], 40)
                self.assertEqual(usage['known_writes'], 5)
                self.assertEqual(usage['known_cost_usd'], .001234)
                self.assertIsNone(usage['cost_usd'])
                self.assertIsNone(usage['in'])

    def test_subtotal_marker_is_fail_closed_and_last_footer_wins(self):
        complete = '[usage] 1 api call(s) · 80 in (40 cached) + 9 out tokens · $0.001234'
        subtotal = complete.replace('[usage] ', '[usage] known subtotal: ')
        partial = measurement.graff_usage(complete + '\n' + subtotal)
        self.assertFalse(partial['usage_complete'])
        self.assertIsNone(partial['cost_usd'])
        self.assertEqual(partial['known_in'], 80)
        self.assertEqual(measurement.graff_usage(subtotal + '\n' + complete),
                         measurement.graff_usage(complete))
        # Recognize the failed-attempt suffix even without the newer prefix.
        failed = complete + ' · totals incomplete: 1 failed request attempt(s) without usage (tokens and cost unknown)'
        self.assertFalse(measurement.graff_usage(failed)['usage_complete'])

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

    def test_wire_captures_are_private_isolated_and_include_rendered_guidance(self):
        with tempfile.TemporaryDirectory() as temp:
            first = Path(temp) / 'sandboxes' / 'first'
            second = Path(temp) / 'sandboxes' / 'second'
            env = {'CODEGRAFF_API_KEY': 'fixture'}
            request_capture.configure(env, first)
            self.assertEqual(env['GRAFF_REQ_STATS'], '1')
            self.assertEqual(Path(env['GRAFF_REQ_DUMP_DIR']).stat().st_mode & 0o777, 0o700)
            request_capture.configure({}, second)
            self.assertNotEqual(request_capture.directory(first), request_capture.directory(second))
            run = request_capture.directory(first) / 'run-fixture'
            run.mkdir()
            body = {'model': 'fixture', 'instructions': 'base + rendered guidance', 'tools': [],
                    'input': [{'role': 'user', 'content': 'first task'}], 'prompt_cache_key': 'lane'}
            (run / 'body-001.json').write_text(json.dumps(body))
            body['input'][0]['content'] = 'different task'
            (run / 'body-002.json').write_text(json.dumps(body))
            body['instructions'] = 'base + different rendered guidance'
            (run / 'body-003.json').write_text(json.dumps(body))
            receipt = request_capture.receipt(first)['request_capture']
            self.assertEqual(receipt['count'], 3)
            a, b, c = receipt['requests']
            self.assertEqual(a['prefix_components_sha256'], b['prefix_components_sha256'])
            self.assertNotEqual(a['body_sha256'], b['body_sha256'])
            self.assertNotEqual(b['prefix_components_sha256'], c['prefix_components_sha256'])
            self.assertEqual(request_capture.receipt(second)['request_capture']['count'], 0)
            self.assertNotIn('rendered guidance', json.dumps(receipt))
            (run / 'body-004.json').write_text('broken')
            self.assertIn('capture_error', request_capture.receipt(first)['request_capture']['requests'][-1])

    def test_capture_evidence_requires_nonempty_parseable_contiguous_bodies(self):
        with tempfile.TemporaryDirectory() as temp:
            sandbox = Path(temp) / 'sandboxes' / 'case'
            request_capture.configure({}, sandbox)
            current = lambda: request_capture.receipt(sandbox)['request_capture']
            self.assertFalse(current()['capture_evidence_ok'])
            run = request_capture.directory(sandbox) / 'run-fixture'
            run.mkdir()
            (run / 'body-001.json').write_text('{"model":"fixture"}')
            self.assertTrue(current()['capture_evidence_ok'])
            (run / 'body-003.json').write_text('{"model":"fixture"}')
            self.assertFalse(current()['capture_evidence_ok'])
            (run / 'body-002.json').write_text('broken')
            self.assertFalse(current()['capture_evidence_ok'])
            self.assertEqual(current()['valid_count'], 2)
            (run / 'body-002.json').write_text('{"model":"fixture"}')
            self.assertTrue(current()['capture_evidence_ok'])
            (run / 'body-000.json').write_text('{}')
            self.assertFalse(current()['capture_evidence_ok'])

    def test_capture_order_is_numeric_with_independent_run_sequences(self):
        with tempfile.TemporaryDirectory() as temp:
            sandbox = Path(temp) / 'sandboxes' / 'case'
            request_capture.configure({}, sandbox)
            root = request_capture.directory(sandbox)
            for name, count in [('run-z', 1001), ('run-a', 2)]:
                run = root / name
                run.mkdir()
                for number in reversed(range(1, count + 1)):
                    (run / f'body-{number:03d}.json').write_text('{"model":"fixture"}')
            captured = request_capture.receipt(sandbox)['request_capture']
            self.assertTrue(captured['capture_evidence_ok'])
            self.assertEqual(captured['order_scope'], 'per_run_body_build')
            self.assertEqual(captured['count'], 1003)
            for name, count in [('run-z', 1001), ('run-a', 2)]:
                rows = [r for r in captured['requests'] if r['run_id'] == name]
                self.assertEqual([r['sequence'] for r in rows], list(range(1, count + 1)))
            (root / 'run-a' / 'body-002.json').unlink()
            (root / 'run-a' / 'body-004.json').write_text('{}')
            self.assertFalse(request_capture.receipt(sandbox)['request_capture']['capture_evidence_ok'])

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
