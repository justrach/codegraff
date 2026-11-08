"""Offline acceptance checks for fixture state, observation evidence, and refs."""
import json
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import unittest

from fixture import CASES, MODES, World, render
from run import correct_answer

RENDERER = Path(__file__).resolve().parents[2] / 'zig-out/bin/nanocua-utility-render'


def text(world, **options):
    result = world.call('get_ui_tree', options)
    return result['content'][0]['text']


def ref_for(observation, title):
    for line in observation.splitlines():
        if '"' + title + '"' in line:
            return int(re.search(r'\[(\d+)\]', line).group(1))
    return None


def scenario(world):
    """Scripted, observation-driven policy for offline fixture validation only."""
    observed = text(world)
    if world.case in ('calculator', 'validation'):
        field = 'Expression' if world.case == 'calculator' else 'Email'
        world.call('set_value', {'ref': ref_for(observed, field), 'value': '7*6' if world.case == 'calculator' else 'not-an-email'})
        world.call('click', {'ref': ref_for(observed, 'Calculate' if world.case == 'calculator' else 'Submit')})
    elif world.case == 'file_info':
        world.call('click', {'ref': ref_for(observed, 'clip.mov')})
    elif world.case == 'toggle':
        world.call('click', {'ref': ref_for(observed, 'Auto save')})
    else:
        if 'value="Privacy"' not in observed:
            observed = text(world, interactive_only=False)
        if 'value="Privacy"' not in observed:
            return False
        # The parent Button ref, not the child's StaticText ref.
        lines = observed.splitlines()
        index = next(i for i, line in enumerate(lines) if 'value="Privacy"' in line)
        ref = int(re.search(r'\[(\d+)\]', lines[index - 1]).group(1))
        world.call('click', {'ref': ref})
    text(world)
    if not world.observed:
        text(world, interactive_only=False, include_frames=False)
    return world.done and world.observed


class UtilityTest(unittest.TestCase):
    def test_catalog_is_the_production_catalog(self):
        tools = render(RENDERER, catalog=True)['tools']
        self.assertEqual(len(tools), 10)
        props = next(t for t in tools if t['name'] == 'get_ui_tree')['inputSchema']['properties']
        self.assertEqual(props['interactive_only']['type'], 'boolean')
        self.assertEqual(props['include_frames']['type'], 'boolean')
        self.assertIs(props['include_frames']['default'], False)

    def test_default_and_frameless_keep_reading_utility(self):
        for mode in ('full', 'no_frames', 'default'):
            for case in CASES:
                with self.subTest(mode=mode, case=case):
                    world = World(case, mode, RENDERER)
                    self.assertTrue(scenario(world))
                    self.assertGreater(world.observation_bytes, 0)

    def test_production_default_keeps_text_refs_and_optional_coordinates(self):
        world = World('calculator', 'default', RENDERER)
        initial = text(world)
        refs = dict(world.refs)
        self.assertIn('Result: 0', initial)
        self.assertNotIn(' @', initial)
        framed = text(world, include_frames=True)
        self.assertIn(' @', framed)
        self.assertEqual(world.refs, refs)
        self.assertEqual(re.sub(r' @-?\d+,-?\d+ \d+x\d+', '', framed), initial)

    def test_controls_only_is_a_negative_control(self):
        for case in CASES:
            with self.subTest(case=case):
                self.assertEqual(scenario(World(case, 'controls_only', RENDERER)), case == 'toggle')

    def test_adaptive_can_recover_missing_text_and_labels(self):
        for case in CASES:
            with self.subTest(case=case):
                world = World(case, 'adaptive', RENDERER)
                self.assertTrue(scenario(world))
                self.assertEqual(world.fallback_reads > 0, case != 'toggle')

    def test_refresh_replaces_refs_instead_of_reusing_old_indices(self):
        world = World('calculator', 'adaptive', RENDERER)
        compact = text(world)
        compact_ref = ref_for(compact, 'Expression')
        full = text(world, interactive_only=False)
        full_ref = ref_for(full, 'Expression')
        self.assertNotEqual(compact_ref, full_ref)
        self.assertTrue(world.call('set_value', {'ref': compact_ref, 'value': '7*6'})['isError'])
        self.assertFalse(world.call('set_value', {'ref': full_ref, 'value': '7*6'})['isError'])

    def test_no_success_without_action_and_post_action_observation(self):
        world = World('calculator', 'full', RENDERER)
        observed = text(world)
        self.assertFalse(world.observed)
        world.call('set_value', {'ref': ref_for(observed, 'Expression'), 'value': '7*6'})
        world.call('click', {'ref': ref_for(observed, 'Calculate')})
        self.assertTrue(world.done)
        self.assertFalse(world.observed)
        text(world)
        self.assertTrue(world.observed)

    def test_omission_notice_is_not_evidence_of_a_toggle_value(self):
        world = World('toggle', 'controls_only', RENDERER)
        observed = text(world)
        world.call('click', {'ref': ref_for(observed, 'Auto save')})
        self.assertTrue(world.done)
        text(world, max_nodes=1)  # Only the window and the "controls only" notice.
        self.assertFalse(world.observed)
        text(world)
        self.assertTrue(world.observed)

    def test_answer_grading_is_not_just_any_prose(self):
        for case in CASES:
            self.assertTrue(correct_answer(case, CASES[case]['answer']))
            self.assertFalse(correct_answer(case, 'I cannot read the result.'))
        self.assertFalse(correct_answer('calculator', '142'))
        self.assertTrue(correct_answer('file_info', '26 seconds, 1080 × 1920, 2,496,326 bytes'))

    def test_mcp_stdio_roundtrip_uses_the_fixture_only(self):
        with tempfile.TemporaryDirectory() as tmp:
            state = Path(tmp) / 'state.json'
            request = '\n'.join(json.dumps(m) for m in (
                {'jsonrpc': '2.0', 'id': 1, 'method': 'initialize'},
                {'jsonrpc': '2.0', 'id': 2, 'method': 'tools/call', 'params': {'name': 'get_ui_tree', 'arguments': {}}},
            )) + '\n'
            done = subprocess.run([sys.executable, str(Path(__file__).with_name('fixture.py')),
                                   '--renderer', str(RENDERER), '--case', 'calculator',
                                   '--mode', 'no_frames', '--state', str(state)],
                                  input=request, text=True, capture_output=True, check=True, timeout=10)
            replies = [json.loads(line) for line in done.stdout.splitlines()]
            self.assertEqual([r['id'] for r in replies], [1, 2])
            self.assertIn('Result: 0', replies[1]['result']['content'][0]['text'])
            self.assertNotIn(' @', replies[1]['result']['content'][0]['text'])
            self.assertEqual(json.loads(state.read_text())['tool_calls'], 1)


if __name__ == '__main__':
    unittest.main()
