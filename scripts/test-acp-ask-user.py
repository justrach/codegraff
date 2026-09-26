#!/usr/bin/env python3
"""ask_user over ACP never waits on a client that cannot show it.

- no capability: the tool returns at once and the turn ends (no freeze)
- clientCapabilities.elicitation.form: standard elicitation/create, answer flows back
- _meta["graff/askUser"]: graff's gui_ask_user + session/answer (apps/native)
"""
import json, os, queue, signal, subprocess, sys, tempfile, threading, time
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parent / 'eval'))
from mock_model import ScriptedModel

QUESTION = 'Which deployment target?'


def tool_results(model):
    out = []
    for body in model.requests:
        for message in body.get('messages', []):
            if message.get('role') == 'tool':
                content = message.get('content')
                out.append(content if isinstance(content, str) else json.dumps(content))
    return out


def run(binary, case):
    model = ScriptedModel([
        {'tool': 'ask_user', 'arguments': {'question': QUESTION, 'options': ['npm', 'GitHub release']}},
        {'text': 'Done.'},
    ])
    caps = {
        'none': {'fs': {}},
        'elicitation': {'fs': {}, 'elicitation': {'form': {}}},
        'legacy': {'fs': {}, '_meta': {'graff/askUser': True}},
    }[case]
    with tempfile.TemporaryDirectory(prefix='acp-ask-user-') as temp:
        env = {k: v for k, v in os.environ.items() if not k.endswith('_API_KEY')}
        config = Path(temp) / 'mcp.json'
        config.write_text('{"mcpServers":{}}')
        env.update(HOME=temp, AI_GATEWAY_API_KEY='local', GRAFF_MCP_CONFIG=str(config), GRAFF_NO_TELEMETRY='1',
                   GRAFF_FLEET='off', GRAFF_NO_SMOLIFY='1', GRAFF_NO_CODEDB_GUARD='1')
        port = model.start(0)
        env['GRAFF_VERCEL_URL'] = f'http://127.0.0.1:{port}/v1/chat/completions'
        proc = subprocess.Popen([binary, 'acp', '--model', 'vercel', '--old', '--no-lean', '--yolo'], cwd=temp, env=env,
                                stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True,
                                start_new_session=True)
        messages = queue.Queue()

        def read():
            for line in proc.stdout:
                try:
                    messages.put(json.loads(line))
                except ValueError:
                    pass
            messages.put(None)
        threading.Thread(target=read, daemon=True).start()

        def send(obj):
            proc.stdin.write(json.dumps({'jsonrpc': '2.0', **obj}) + '\n')
            proc.stdin.flush()

        seen = []

        def wait(id, timeout=30):
            deadline = time.monotonic() + timeout
            while True:
                m = messages.get(timeout=max(.01, deadline - time.monotonic()))
                assert m is not None, 'worker exited'
                seen.append(m)
                if m.get('id') == id and 'method' not in m:
                    return m
                if m.get('method') == 'elicitation/create':
                    assert case == 'elicitation', m
                    params = m['params']
                    assert params['mode'] == 'form' and params['message'] == QUESTION, params
                    answer = params['requestedSchema']['properties']['answer']
                    assert answer['enum'] == ['npm', 'GitHub release'], answer
                    # A stale ID must not answer the live question.
                    send({'id': 'graff-elicit-0', 'result': {'action': 'accept', 'content': {'answer': 'wrong'}}})
                    send({'id': m['id'], 'result': {'action': 'accept', 'content': {'answer': 'npm'}}})
                update = (m.get('params') or {}).get('update') or {}
                if update.get('sessionUpdate') == 'gui_ask_user':
                    assert case == 'legacy', m
                    send({'method': 'session/answer', 'params': {'sessionId': sid, 'text': 'npm'}})

        try:
            send({'id': 1, 'method': 'initialize', 'params': {'protocolVersion': 1, 'clientCapabilities': caps}})
            wait(1)
            send({'id': 2, 'method': 'session/new', 'params': {'cwd': temp, 'mcpServers': []}})
            sid = wait(2)['result']['sessionId']
            started = time.monotonic()
            send({'id': 3, 'method': 'session/prompt', 'params': {'sessionId': sid, 'prompt': [{'type': 'text', 'text': 'Ask me.'}]}})
            done = wait(3, timeout=20)
            assert done.get('result', {}).get('stopReason') == 'end_turn', done
            results = tool_results(model)
            assert results, 'ask_user result never reached the model'
            methods = {m.get('method') for m in seen}
            updates = {((m.get('params') or {}).get('update') or {}).get('sessionUpdate') for m in seen}
            if case == 'none':
                assert 'cannot show questions' in results[-1], results
                assert 'elicitation/create' not in methods and 'gui_ask_user' not in updates
                assert time.monotonic() - started < 10, 'ask_user waited on a client that cannot answer'
            else:
                assert 'npm' in results[-1] and 'wrong' not in results[-1], results
            print('PASS ACP ask_user', case, flush=True)
        finally:
            os.killpg(proc.pid, signal.SIGKILL)
            proc.wait(timeout=3)
            model.stop()


if __name__ == '__main__':
    binary = str(Path(sys.argv[1] if len(sys.argv) > 1 else 'zig-out/bin/graff').resolve())
    for case in ['none', 'elicitation', 'legacy']:
        run(binary, case)
