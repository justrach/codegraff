"""Two live children: target handles come from actual launch receipts, not order."""
import json
import re

from mock_model import ScriptedModel
from subagent_feedback_model import bash, wait_file


class RoutingModel(ScriptedModel):
    def __init__(self, reverse=False):
        super().__init__([])
        self.order = ['layout', 'storage'] if reverse else ['storage', 'layout']
        self.parent_step = 0
        self.child_steps = {'layout': 0, 'storage': 0}
        self.checked = set()
        self.handles = {}

    def next_reply(self, body):
        super().next_reply(body)
        messages = body.get('messages', [])
        first = next((m for m in messages if m.get('role') == 'user'), {})
        for role in self.order:
            if f'ROUTING_CHILD_{role}' in json.dumps(first):
                return self.child(role, messages)
        return self.parent(messages)

    def child(self, role, messages):
        step = self.child_steps[role]
        self.child_steps[role] += 1
        if step == 0:
            return bash(f"from pathlib import Path\nPath('{role}-ready').touch()\n" + wait_file('release-both') + "print('CHILD_TOOL_FINISHED')")
        notes = [m for m in messages if m.get('role') == 'user' and '[Parent task feedback]' in json.dumps(m)]
        expected = 'LAYOUT_NOTE: preserve keyboard focus' if role == 'layout' else 'STORAGE_NOTE: preserve transaction ordering'
        other = 'STORAGE_NOTE' if role == 'layout' else 'LAYOUT_NOTE'
        valid = step == 1 and len(notes) == 1 and expected in json.dumps(notes) and other not in json.dumps(messages)
        if valid:
            self.checked.add(role)
        return {'text': f'{role.upper()}_ROUTING_OK' if valid else 'ROUTING_FAILED'}

    def parent(self, messages):
        step = self.parent_step
        self.parent_step += 1
        outputs = '\n'.join(str(m.get('content', '')) for m in messages if m.get('role') == 'tool')
        for handle, label in re.findall(r'\[agent (\d+) started: ([^\]]+)\]', outputs):
            self.handles[label] = int(handle)
        if step < 2:
            role = self.order[step]
            return {'tool': 'subagent', 'arguments': {'description': role, 'prompt': f'ROUTING_CHILD_{role}: work on {role}.', 'run_in_background': True}}
        if step == 2:
            return bash(wait_file('layout-ready') + wait_file('storage-ready'))
        if step in (3, 4, 5):
            role = 'storage' if step == 4 else 'layout'
            # The invalid handle is deliberately attempted between valid sends.
            handle = 999999 if step == 5 else self.handles[role]
            note = 'LAYOUT_NOTE: preserve keyboard focus' if role == 'layout' else 'STORAGE_NOTE: preserve transaction ordering'
            return {'tool': 'agent_message', 'arguments': {'id': handle, 'message': note}}
        if step == 6:
            return bash("from pathlib import Path; Path('release-both').touch()")
        if step in (7, 8):
            return {'tool': 'agent_output', 'arguments': {'id': self.handles[self.order[step - 7]], 'wait_ms': 1}}
        valid = self.checked == {'layout', 'storage'} and all(self.child_steps[r] == 2 for r in self.order)
        valid = valid and all(s in outputs for s in ('LAYOUT_ROUTING_OK', 'STORAGE_ROUTING_OK', 'agent is not live'))
        return {'text': 'TWO_CHILD_ROUTING_OK' if valid else 'TWO_CHILD_ROUTING_FAILED'}
