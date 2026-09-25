#!/usr/bin/env python3
"""Offline ACP child-session regression through the real subagent tool path."""
import importlib.util
import sys
import tempfile
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('acp_load', REPO / 'scripts/test-acp-session-load.py')
load = importlib.util.module_from_spec(spec)
spec.loader.exec_module(load)


def updates(client):
    return [(index, event['params']['sessionId'], event['params']['update'])
            for index, event in enumerate(client.events)
            if event.get('method') == 'session/update']


def run(binary, preview, capability, json_mode=False):
    with tempfile.TemporaryDirectory(prefix='graff-acp-child-') as temporary:
        work = Path(temporary)
        home = work / 'home'
        home.mkdir()
        (work / 'example.txt').write_text('SUBAGENT-FIXTURE-CONTENT\n')
        model = load.ScriptedModel([
            {'tool': 'subagent', 'arguments': {'description': 'Inspect example',
                'prompt': 'Read example.txt and report its content.', 'isolation': 'shared_cwd',
                'run_in_background': False}},
            {'text': 'Child is inspecting.', 'tool': 'read_file',
                'arguments': {'path': 'example.txt'}},
            {'text': 'Child found SUBAGENT-FIXTURE-CONTENT.'},
            {'text': 'Parent received the child report.'},
        ], exhausted_text='unexpected extra model call')
        port = model.start(0)
        env = {'GRAFF_NO_NATIVE_FOLD': '1'}
        if preview:
            env['GRAFF_ACP_DRAFT_SUBAGENTS'] = '1'
        args = ('--max-model-calls', '6', '--max-run-tool-calls', '8')
        if json_mode:
            args += ('--json',)
        client = load.Acp(binary, work, home, port, extra_env=env, extra_args=args)
        try:
            capabilities = {'subagents': {}} if capability else {}
            client.request('initialize', {'protocolVersion': 1,
                                          'clientCapabilities': capabilities})
            sid = client.request('session/new', {'cwd': str(work),
                                                'mcpServers': []})['result']['sessionId']
            response = client.request('session/prompt', {'sessionId': sid,
                'prompt': [{'type': 'text', 'text': 'Delegate the local inspection.'}]}, timeout=25)
            assert response['result']['stopReason'] == 'end_turn', response
            rows = updates(client)
            parent_calls = [(i, update) for i, session, update in rows
                            if session == sid and update.get('sessionUpdate') == 'tool_call'
                            and update.get('_meta', {}).get('graff/toolName') == 'subagent']
            assert len(parent_calls) == 1, rows
            parent_id = parent_calls[0][1]['toolCallId']
            child_updates = [(i, update) for i, session, update in rows
                             if session == sid and update.get('sessionUpdate') == 'subagent_update']
            if not (preview and capability):
                assert not child_updates, rows
                assert all(session == sid for _, session, _ in rows), rows
                return
            assert len(child_updates) == 2, rows
            announced_at, announced = child_updates[0]
            finished_at, finished = child_updates[1]
            child_id = announced['subagentSessionId']
            assert child_id != sid
            assert announced['task'] == 'Read example.txt and report its content.'
            assert announced['_meta']['graff/parentToolCallId'] == parent_id
            assert finished['subagentSessionId'] == child_id
            assert finished['state'] == 'completed'
            assert finished['_meta']['graff/parentToolCallId'] == parent_id
            activity = [(i, update) for i, session, update in rows if session == child_id]
            assert any(update.get('sessionUpdate') == 'tool_call' and
                       update.get('_meta', {}).get('graff/toolName') == 'read_file'
                       for _, update in activity), activity
            assert any('SUBAGENT-FIXTURE-CONTENT' in str(update)
                       for _, update in activity), activity
            assert parent_calls[0][0] < announced_at < activity[0][0]
            assert all(announced_at < i < finished_at for i, _ in activity), rows
            assert finished_at < next(i for i, event in enumerate(client.events)
                                      if event.get('id') == client.next_id)
        finally:
            client.close()
            model.stop()


if __name__ == '__main__':
    binary = Path(sys.argv[1] if len(sys.argv) > 1 else REPO / 'zig-out/bin/graff').resolve()
    for preview, capability in ((False, True), (True, False), (True, True)):
        run(binary, preview, capability)
    run(binary, True, True, json_mode=True)
    print('ACP child sessions: gated fallback, negotiated announcement, child activity, terminal, --json')
