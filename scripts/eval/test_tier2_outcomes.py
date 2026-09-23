#!/usr/bin/env python3
"""A claimed success cannot substitute for independent workspace outcomes."""
import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location('tier2', Path(__file__).parents[1]/'eval-tier2.py')
tier2 = importlib.util.module_from_spec(spec)
spec.loader.exec_module(tier2)


class OutcomeIntegrity(unittest.TestCase):
    case = {'verify_command': ['python3', '-c', 'assert actual == expected'],
            'assert': [{'final_text_contains': 'passed'},
                       {'file_equals': {'path': 'settings.json', 'content': '{"limit":2}'}}]}

    def run_value(self, code=0, files=None):
        return tier2.Run([{'type': 'turn', 'text': 'All tests passed.'}], [], '', 0,
                         files if files is not None else {'settings.json': '{"limit":2}'},
                         {'exit_code': code, 'stdout': 'passed', 'stderr': ''})

    def test_green_prose_and_stdout_cannot_hide_failed_verifier(self):
        self.assertTrue(tier2.evaluate(self.case, self.run_value(code=7)))

    def test_missing_verifier_fails(self):
        run = self.run_value()
        run.verification = None
        self.assertTrue(tier2.evaluate(self.case, run))

    def test_timeout_is_failure(self):
        self.assertTrue(tier2.evaluate(self.case, self.run_value(code=None)))

    def test_missing_or_wrong_file_fails(self):
        for files in ({}, {'settings.json': '{"limit":1}'}):
            self.assertTrue(tier2.evaluate(self.case, self.run_value(files=files)))

    def test_matching_file_and_independent_pass_succeed(self):
        self.assertEqual([], tier2.evaluate(self.case, self.run_value()))

    def test_order_inspects_calls_not_schema_or_prose(self):
        case = {'assert': [{'request_tool_calls_at_most': {'index': 0, 'name': 'edit_file', 'count': 0}}]}
        run = self.run_value()
        run.requests = [{'messages': [{'role': 'system', 'content': 'edit_file new_string schema'}]}]
        self.assertEqual([], tier2.evaluate(case, run))
        run.requests[0]['messages'].append({'role': 'assistant', 'tool_calls': [{'function': {'name': 'edit_file'}}]})
        self.assertTrue(tier2.evaluate(case, run))

    def test_oneshot_assertions_require_actual_wire_count_and_exact_stdout(self):
        case = {'assert': [{'request_count': 1}, {'stdout_equals': 'pong\n'}]}
        run = tier2.Run([], [{}], '', 0, stdout='pong\n')
        self.assertEqual([], tier2.evaluate(case, run))
        for count in (0, 2):
            run.requests = [{}] * count
            self.assertTrue(tier2.evaluate(case, run))
        run.requests = [{}]
        for output in ('', 'pong', 'pong\nextra\n'):
            run.stdout = output
            self.assertTrue(tier2.evaluate(case, run))
        run.stdout = 'pong\n'
        run.requests = []
        self.assertEqual([], tier2.evaluate(case, run, live=True))


if __name__ == '__main__':
    unittest.main()
