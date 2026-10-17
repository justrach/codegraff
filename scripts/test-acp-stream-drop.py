#!/usr/bin/env python3
"""#1639 over ACP: a turn whose stream keeps dropping ends with the same saved
row as the REPL ("[response ended early: connection dropped]"), not with no
assistant reply at all. GRAFF_FORCE_DROP_ALWAYS makes every live attempt return
error.StreamDropped before any network call, so no provider or key is used.
"""
import json
import os
from pathlib import Path
import queue
import signal
import subprocess
import sys
import tempfile
import threading
import time

MARKER = '[response ended early: connection dropped]'


def main():
    binary = str(Path(sys.argv[1] if len(sys.argv) > 1 else 'zig-out/bin/graff').resolve())
    with tempfile.TemporaryDirectory(prefix='graff-acp-drop-') as temp:
        env = {k: v for k, v in os.environ.items() if not k.endswith('_API_KEY')}
        config = Path(temp) / 'mcp.json'
        config.write_text('{"mcpServers":{}}')
        env.update(HOME=temp, CODEGRAFF_API_KEY='fake-test-key', GRAFF_MCP_CONFIG=str(config),
                   GRAFF_NO_TELEMETRY='1', GRAFF_FLEET='off', GRAFF_NO_SMOLIFY='1',
                   GRAFF_NO_CODEDB_GUARD='1', GRAFF_FORCE_DROP_ALWAYS='1')
        proc = None
        try:
            proc = subprocess.Popen([binary, 'acp', '--yolo'], cwd=temp, env=env,
                                    stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                    stderr=subprocess.DEVNULL, text=True, start_new_session=True)
            events = queue.Queue()

            def reader():
                for line in proc.stdout:
                    try:
                        events.put(json.loads(line))
                    except ValueError:
                        pass
                events.put(None)
            threading.Thread(target=reader, daemon=True).start()

            def call(method, params, id, budget=25):
                proc.stdin.write(json.dumps(dict(jsonrpc='2.0', method=method, params=params, id=id)) + '\n')
                proc.stdin.flush()
                deadline = time.monotonic() + budget
                while True:
                    value = events.get(timeout=max(.01, deadline - time.monotonic()))
                    assert value is not None, 'ACP worker exited before replying'
                    if value.get('id') == id:
                        return value

            call('initialize', {'protocolVersion': 1}, 1)
            sid = call('session/new', {}, 2)['result']['sessionId']
            # Every reconnect drops too, so the whole drop budget (with its
            # growing pauses) runs before the turn ends.
            failed = call('session/prompt', {'sessionId': sid, 'prompt': [{'type': 'text', 'text': 'hello'}]}, 3, budget=90)
            assert 'StreamDropped' in json.dumps(failed.get('error')), failed
            saved = list((Path(temp) / '.graff/sessions').glob('*.session.json'))
            assert saved, 'the failed turn was not saved'
            rows = [m for p in saved for m in json.loads(p.read_text()).get('messages', [])]
            texts = [json.dumps(m) for m in rows if isinstance(m, dict) and m.get('role') == 'assistant']
            assert any(MARKER in t for t in texts), f'no end marker saved: {texts}'
            assert not any('interrupted by user' in t for t in texts), texts
            print(f'PASS ACP stream drop: turn saved as {MARKER!r}, never a user interrupt')
        finally:
            if proc:
                try:
                    os.killpg(proc.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
                proc.wait(timeout=2)
                for pipe in (proc.stdin, proc.stdout):
                    if pipe:
                        pipe.close()


if __name__ == '__main__':
    main()
