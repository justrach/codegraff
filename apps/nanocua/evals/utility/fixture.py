#!/usr/bin/env python3
"""Synthetic app state behind MCP; production Zig code formats every observation.

This fixture has no desktop access. It deliberately does NOT emulate macOS AX,
Space visibility, native input delivery, or the complete nanocua backend.
"""
import argparse
import json
import subprocess
import sys
from pathlib import Path

CASES = {
    'calculator': {
        'prompt': 'In Calculator, enter 7*6, activate Calculate, and report the displayed result.',
        'answer': '42',
    },
    'file_info': {
        'prompt': 'In Files, open the info for clip.mov and report its exact duration, dimensions, and size in bytes.',
        'answer': '26 seconds; 1080x1920; 2496326 bytes',
    },
    'validation': {
        'prompt': 'In Signup, enter not-an-email in Email, submit it, and report the exact validation message.',
        'answer': 'Email must contain @ and a domain.',
    },
    'child_label': {
        'prompt': 'In Settings, open Privacy (the buttons have child labels) and report the access level shown there.',
        'answer': 'Team only',
    },
    'toggle': {
        'prompt': 'In Preferences, turn Auto save on and verify that its value is on.',
        'answer': 'on',
    },
}
MODES = ('full', 'no_frames', 'controls_only', 'adaptive', 'default')


def render(binary, **request):
    done = subprocess.run([str(binary)], input=json.dumps(request), text=True,
                          capture_output=True, check=True, timeout=10)
    return json.loads(done.stdout)


class World:
    def __init__(self, case, mode, renderer):
        self.case, self.mode, self.renderer = case, mode, renderer
        self.value, self.page, self.focus = '', '', None
        self.done = self.observed = False
        self.refs = {}
        self.events = []
        self.observation_bytes = self.reply_bytes = self.wire_bytes = 0
        self.fallback_reads = 0
        self.had_compact = False

    def nodes(self):
        nodes = []

        def add(key, role, title='', value='', depth=1, **kw):
            node = dict(role='AX' + role, title=title, value=value,
                        frame=[10, 30 + len(nodes) * 28, 280, 24], **kw)
            nodes.append(dict(key=key, node=node, depth=depth))

        add('window', 'Window', self.case, depth=0)
        if self.case == 'calculator':
            add('intro', 'StaticText', value='Enter an expression, then Calculate.')
            add('input', 'TextField', 'Expression', self.value)
            add('submit', 'Button', 'Calculate')
            add('result', 'StaticText', value='Result: ' + ('42' if self.done else '0'))
        elif self.case == 'file_info':
            add('group', 'Group', 'Files')
            for name in ('notes.txt', 'clip.mov', 'cover.png'):
                add(name, 'Button', name, depth=2)
            if self.done:
                add('info', 'StaticText', value=CASES[self.case]['answer'])
        elif self.case == 'validation':
            add('intro', 'StaticText', value='Use your work email to continue.')
            add('input', 'TextField', 'Email', self.value)
            add('submit', 'Button', 'Submit')
            if self.done:
                add('error', 'StaticText', value=CASES[self.case]['answer'])
        elif self.case == 'child_label':
            for name in ('General', 'Privacy', 'Notifications'):
                add(name, 'Button')
                add(name + '-label', 'StaticText', value=name, depth=2)
            if self.page:
                add('heading', 'StaticText', value=self.page)
            if self.done:
                add('access', 'StaticText', value='Access level: Team only')
        else:
            add('help', 'StaticText', value='Changes are stored automatically when enabled.')
            add('toggle', 'CheckBox', 'Auto save', 'on' if self.done else 'off')
        return nodes

    def observe(self, args):
        opts = dict(args)
        if self.mode == 'full':
            opts.update(interactive_only=False, include_frames=True)
        elif self.mode == 'no_frames':
            opts.update(interactive_only=False, include_frames=False)
        elif self.mode == 'controls_only':
            opts.update(interactive_only=True, include_frames=False)
        elif self.mode == 'adaptive':
            opts.setdefault('interactive_only', True)
            opts['include_frames'] = False
        # 'default' passes options through to production parsing unchanged.
        interactive = opts.get('interactive_only', False)
        if self.had_compact and not interactive:
            self.fallback_reads += 1
        self.had_compact |= interactive
        nodes = self.nodes()
        result = render(self.renderer, nodes=[{k: n[k] for k in ('node', 'depth')} for n in nodes], options=opts)
        self.refs = {i + 1: nodes[index]['key'] for i, index in enumerate(result['indices'])}
        text = result['text']
        self.observation_bytes += len(text.encode())
        # Success must be observed AFTER the action, not merely guessed.
        result_key = {'calculator': 'result', 'file_info': 'info',
                      'validation': 'error', 'child_label': 'access', 'toggle': 'toggle'}[self.case]
        if self.done and any(nodes[i]['key'] == result_key and
                             CASES[self.case]['answer'] in nodes[i]['node']['value']
                             for i in result['indices']):
            self.observed = True
        return text, False

    def call(self, name, args):
        if name == 'get_ui_tree':
            answer, error = self.observe(args)
        elif name == 'list_apps':
            answer, error = 'Fixture pid 1', False
        elif name == 'open_app':
            answer, error = 'done', False
        else:
            answer, error = self.act(name, args)
        self.events.append(dict(tool=name, arguments=args, error=error))
        self.reply_bytes += len(answer.encode())
        return dict(content=[dict(type='text', text=answer)], isError=error)

    def act(self, name, args):
        key = self.refs.get(args.get('ref'))
        if name in ('click', 'set_value') and key is None:
            return 'Unknown ref: read get_ui_tree first.', True
        if name in ('type_text', 'set_value'):
            target = key or self.focus
            if target != 'input':
                return 'Select the input field by ref.', True
            self.value = args.get('text', args.get('value', ''))
            return 'done', False
        if name == 'press_key' and args.get('keys') in ('enter', 'return'):
            key = 'submit'
        elif name != 'click':
            return 'This fixture supports tree, ref clicks, typing, values, and Enter only.', True
        if key == 'input':
            self.focus = key
        elif key == 'submit':
            self.done = self.value == ('7*6' if self.case == 'calculator' else 'not-an-email')
        elif self.case == 'file_info' and key == 'clip.mov':
            self.done = True
        elif self.case == 'child_label' and key in ('General', 'Privacy', 'Notifications'):
            self.page = key
            self.done = key == 'Privacy'
        elif key == 'toggle':
            self.done = not self.done
        else:
            return 'That element has no action in this fixture.', True
        return 'done', False

    def summary(self):
        return dict(action_succeeded=self.done, success_observed=self.observed,
                    tool_calls=len(self.events), observation_bytes=self.observation_bytes,
                    reply_text_bytes=self.reply_bytes, wire_bytes=self.wire_bytes,
                    fallback_reads=self.fallback_reads, events=self.events)


def serve(args):
    world = World(args.case, args.mode, args.renderer)
    catalog = render(args.renderer, catalog=True)
    for line in sys.stdin:
        msg = json.loads(line)
        if 'id' not in msg:
            continue
        method = msg.get('method')
        if method == 'initialize':
            result = dict(protocolVersion='2025-06-18', capabilities={'tools': {}},
                          serverInfo={'name': 'nanocua-utility-fixture', 'version': '1'})
        elif method == 'tools/list':
            result = catalog
        elif method == 'tools/call':
            params = msg['params']
            result = world.call(params['name'], params.get('arguments', {}))
        else:
            result = {}
        response = json.dumps(dict(jsonrpc='2.0', id=msg['id'], result=result), separators=(',', ':'))
        if method == 'tools/call':
            world.wire_bytes += len(response.encode()) + 1
        Path(args.state).write_text(json.dumps(world.summary()))
        print(response, flush=True)


if __name__ == '__main__':
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--renderer', required=True)
    p.add_argument('--case', choices=CASES, required=True)
    p.add_argument('--mode', choices=MODES, required=True)
    p.add_argument('--state', required=True)
    serve(p.parse_args())
