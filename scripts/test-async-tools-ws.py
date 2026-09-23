#!/usr/bin/env python3
"""Offline native async overlap and no-replay checks over real WebSockets."""
import argparse
import http.server
import json
import os
from pathlib import Path
import tempfile
import threading
import time

from codex_ws_mock import CodexMock, USAGE
from pty_harness import PtySession


def exercise(binary, root, mode):
    case = root / mode
    case.mkdir(mode=0o700)
    records = []
    started = threading.Event()
    release = threading.Event()
    def record(event, **fields):
        records.append(dict(event=event, time=time.monotonic(), **fields))

    class Lookup(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            record('lookup-start')
            started.set()
            release.wait(8)
            payload = b'LOOKUP_RESULT_OK'
            self.send_response(200)
            self.send_header('Content-Length', str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)
            record('lookup-end')
        def log_message(self, *_args):
            pass

    lookup = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Lookup)
    threading.Thread(target=lookup.serve_forever, daemon=True).start()

    def events(request):
        record('request', transport=request.transport, body=request.body)
        outputs = [i for i in request.body.get('input', [])
                   if i.get('type') == 'function_call_output' and i.get('call_id') == 'ws_lookup']
        if outputs:
            record('delivered', count=len(outputs), correct='LOOKUP_RESULT_OK' in outputs[0].get('output', ''))
            yield {'type': 'response.output_item.done', 'item': {
                'type': 'message', 'role': 'assistant', 'content': [
                    {'type': 'output_text', 'text': 'ASYNC_WS_DONE'}]}}
        else:
            definition = next(t for t in request.body['tools'] if t.get('name') == 'webfetch')
            record('advertised', enabled=definition.get('async', False))
            item = dict(type='function_call', call_id='ws_lookup', name='webfetch',
                        arguments=json.dumps({'url': f'http://127.0.0.1:{lookup.server_port}/lookup'}))
            if mode != 'off':
                item['async'] = True
            yield {'type': 'response.output_item.added', 'item': {'type': 'tool_search_call'}}
            yield {'type': 'response.output_item.done', 'item': {'type': 'tool_search_call'}}
            yield {'type': 'response.output_item.done', 'item': {'type': 'tool_search_output'}}
            yield {'type': 'response.output_item.done', 'item': item}
            if mode == 'duplicate':
                yield {'type': 'response.output_item.done', 'item': item}
            if mode != 'off':
                record('overlap-observed', started=started.wait(4))
            record('independent-prose')
            yield {'type': 'response.output_text.delta', 'delta': 'INDEPENDENT_WORK'}
            if mode in ('context-error', 'auth-error'):
                message = 'context_length_exceeded' if mode == 'context-error' else 'Provided authentication token is expired'
                record('terminal-failure', message=message)
                release.set()
                yield {'type': 'response.failed', 'response': {'error': {'code': message, 'message': message}}}
                return
            if mode == 'drop':
                record('socket-drop')
                release.set()
                raise ConnectionError('intentional disconnect after async dispatch')
        record('response-completed')
        yield {'type': 'response.completed', 'response': {'id': 'resp_ws_async', 'usage': dict(USAGE)}}
        release.set()

    # This iterable is deliberately streamed, so the callback can wait between
    # frames. CodexMock's second iteration (error scan) sees an exhausted iterator.
    mock = CodexMock(events_for_request=events)
    port = mock.start()
    try:
        (case / 'auth.json').write_text(json.dumps({'tokens': {
            'access_token': 'local-fixture', 'account_id': 'local-fixture'}}))
        (case / '.simple-harness-model').write_text('codex\ngpt-6-sol\n')
        (case / 'mcp.json').write_text('{"mcpServers":{}}')
        shim = case / 'bin'
        shim.mkdir()
        (shim / 'security').write_text('#!/bin/sh\nexit 44\n')
        (shim / 'security').chmod(0o700)
        env = dict(HOME=str(case), CODEX_HOME=str(case), PATH=f'{shim}:/usr/bin:/bin',
                   TERM='dumb', GRAFF_CODEX_URL=f'http://127.0.0.1:{port}/responses',
                   GRAFF_MCP_CONFIG=str(case/'mcp.json'), GRAFF_ASYNC_TOOLS='0' if mode == 'off' else '1',
                   GRAFF_NO_NATIVE_FOLD='1', GRAFF_NO_CODEDB_GUARD='1', GRAFF_NO_TELEMETRY='1',
                   GRAFF_FLEET='off', GRAFF_NO_ADOPT='1', GRAFF_NO_SMOLIFY='1',
                   GRAFF_BEHAVIOR_UPLOAD='off', NO_COLOR='1')
        (case/'.harness').mkdir()
        (case/'.harness/settings.json').write_text('{"ai_title":false,"session_recap":false}')
        with PtySession(str(binary), ['--old', '--no-lean', '--max-model-calls', '3'],
                        cwd=str(case), env=env,
                        unset_env=[key for key in os.environ if key not in env], timeout=15) as session:
            session.wait_for_prompt()
            cursor = len(session.raw)
            session.send_line('Run the fixture lookup and report its result.')
            if mode not in ('drop', 'context-error', 'auth-error'):
                session.wait_for_literal('ASYNC_WS_DONE', start=cursor)
            elif mode == 'drop':
                session.wait_for_literal('[turn aborted:', start=cursor)
            else:
                session.wait_for_literal('codex api error', start=cursor)
            session.wait_for_prompt(start=cursor)
            session.send_key('ctrl-d')
            run = session.read_until_exit(5)
        (case/'stdout').write_text(run.text)
        (case/'events.json').write_text(json.dumps(records, indent=2))
        by = lambda event: [r for r in records if r['event'] == event]
        requests = by('request')
        assert requests and all(r['transport'] == 'ws' for r in requests), records
        assert len(by('lookup-start')) == 1, (records, run.text)
        assert by('advertised')[0]['enabled'] == (mode != 'off'), records
        if mode in ('context-error', 'auth-error'):
            assert len(requests) == 1, records
            assert by('terminal-failure')[0]['message'] in run.text, run.text
            assert 'AsyncToolStreamFailed' not in run.text, run.text
            assert 'emergency-trimmed' not in run.text, run.text
        elif mode == 'drop':
            assert '[turn aborted:' in run.text and len(requests) == 1, (records, run.text)
            assert by('lookup-start')[0]['time'] < by('socket-drop')[0]['time'], records
        else:
            assert run.exit_code == 0 and 'ASYNC_WS_DONE' in run.text, (records, run.text)
            assert len(requests) == 2, records
            delivered = by('delivered')
            assert len(delivered) == 1 and delivered[0]['count'] == 1 and delivered[0]['correct'], records
            begin = by('lookup-start')[0]['time']
            terminal = by('response-completed')[0]['time']
            assert (begin >= terminal) if mode == 'off' else (begin < terminal), records
            if mode != 'off':
                assert by('overlap-observed')[0]['started'], records
                assert by('independent-prose')[0]['time'] < by('lookup-end')[0]['time'], records
        return dict(mode=mode, requests=len(requests), lookup_calls=len(by('lookup-start')), exit=run.exit_code)
    finally:
        release.set()
        mock.stop()
        lookup.shutdown()
        lookup.server_close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--graff', required=True, type=Path)
    args = parser.parse_args()
    root = Path(tempfile.mkdtemp(prefix='graff-async-ws-'))
    root.chmod(0o700)
    print(f'Private evidence: {root}', flush=True)
    for mode in ('on', 'off', 'duplicate', 'drop', 'context-error', 'auth-error'):
        print(json.dumps(exercise(args.graff.resolve(), root, mode)), flush=True)
    print('PASS native async WebSocket overlap and no replay', flush=True)


if __name__ == '__main__':
    main()
