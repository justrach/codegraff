#!/usr/bin/env python3
"""Exercise native extensions with synthetic local model fixtures; no GUI."""
import argparse
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time

from codex_ws_mock import CodexMock, REPLY_TEXT

PLUGIN = '''import json,sys
from pathlib import Path
request=json.loads(sys.argv[-1])
assert request['version']==1
state=Path('counter.txt')
count=int(state.read_text()) if state.exists() else 0
if request['event']=='action':
    assert request['data']=={'action':'increment'}
    count+=1
    state.write_text(str(count))
root={'kind':'column','children':[{'kind':'stat','label':'Count','value':str(count)},{'kind':'button','label':'Add','action':'increment'}]}
if Path('bad-panel').exists(): root={'kind':'html','text':'not executable'}
print(json.dumps({'version':1,'panel':{'title':'Synthetic counter','root':root}}))
'''


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--graff', default='zig-out/bin/graff')
    args = parser.parse_args()
    binary = str(Path(args.graff).resolve())
    with tempfile.TemporaryDirectory(prefix='graff-native-extensions-') as tmp:
        root = Path(tmp)
        (root / '.harness').mkdir()
        (root / 'home').mkdir()
        (root / 'plugin.py').write_text(PLUGIN)
        settings = root / '.harness/settings.json'
        config = {'runtime_plugins': [{'id': 'fixture', 'trusted': True,
                  'command': [sys.executable, 'plugin.py'],
                  'events': ['ui', 'action'], 'timeout_ms': 1000}]}
        def save():
            settings.write_text(json.dumps(config))
        save()
        env = {key: os.environ[key] for key in ('PATH', 'TMPDIR', 'LANG', 'SystemRoot') if key in os.environ}
        env.update(HOME=str(root/'home'), USERPROFILE=str(root/'home'),
                   GRAFF_NO_TELEMETRY='1', GRAFF_FLEET='off', GRAFF_LEARN_AUTO='off',
                   GRAFF_BEHAVIOR_UPLOAD='off', NO_COLOR='1')
        def run(*words, ok=True):
            result = subprocess.run([binary, *words], cwd=root, env=env,
                                    capture_output=True, text=True, timeout=20)
            assert (result.returncode == 0) == ok, (words, result.returncode, result.stderr)
            return result.stdout
        def panels():
            result = json.loads(run('extensions', 'list', '--json'))
            assert result['version'] == 1
            return result['panels']
        def count(panel):
            return panel['root']['children'][0]['value']
        assert count(panels()[0]) == '0'
        action = json.loads(run('extensions', 'invoke', 'fixture', 'increment'))
        assert count(action['panel']) == '1'
        assert count(panels()[0]) == '1'
        run('extensions', 'invoke', 'fixture', 'not-declared', ok=False)
        assert (root/'counter.txt').read_text() == '1'
        run('plugins', 'disable', 'fixture')
        assert panels() == []
        run('plugins', 'enable', 'fixture')
        assert count(panels()[0]) == '1'
        # CLI mutations preserve unrelated formatter/runtime configuration.
        updated = json.loads(settings.read_text())
        assert updated['runtime_plugins'] == config['runtime_plugins']
        config = updated
        config['policies'] = [{'action':'plugin.use','resource':'fixture','effect':'deny'}]
        save()
        assert panels() == []
        run('extensions', 'invoke', 'fixture', 'increment', ok=False)
        assert (root/'counter.txt').read_text() == '1'
        config.pop('policies')
        config['runtime_plugins'][0]['trusted'] = False
        save()
        assert panels() == []
        config['runtime_plugins'][0]['trusted'] = True
        save()
        (root/'bad-panel').write_text('invalid')
        run('extensions', 'list', '--json', ok=False)
        assert (root/'counter.txt').read_text() == '1'
        # Responses success must notify observers (shared SSE/WS completion arm).
        (root/'plugin.py').write_text("import json,sys\nfrom pathlib import Path\nr=json.loads(sys.argv[-1])\nwith Path('events.jsonl').open('a') as f:f.write(json.dumps(r['event'])+'\\n')\nprint(json.dumps({'version':1}))\n")
        config = {'ai_title': False, 'session_recap': False, 'runtime_plugins': [{
            'id': 'fixture', 'trusted': True, 'command': [sys.executable, 'plugin.py'],
            'events': ['before_request', 'after_response']}]}
        save()
        credential = root/'home/.graff/credentials/chatgpt-new.json'
        credential.parent.mkdir(parents=True)
        credential.write_text(json.dumps({'access_token': 'synthetic-local-fixture',
            'expires_at': int(time.time()) + 3600, 'scopes': ['chatgpt.tokens.use.direct']}))
        mock = CodexMock()
        port = mock.start()
        try:
            env['GRAFF_CHATGPT_URL'] = f'http://127.0.0.1:{port}/backend-api/codex/responses'
            for transport in ('off',):
                env['GRAFF_CODEX_WS'] = transport
                (root/'events.jsonl').unlink(missing_ok=True)
                answer = run('-p', 'Reply with the synthetic fixture answer.', '--model', 'chatgpt-new/gpt-6.1-terra',
                             '--no-resume', '--no-telemetry', '--max-model-calls', '1')
                assert REPLY_TEXT in answer, answer
                events = [json.loads(line) for line in (root/'events.jsonl').read_text().splitlines()]
                assert events == ['before_request', 'after_response'], (transport, events)
            assert mock.sse_turns > 0
        finally:
            mock.stop()
    print('PASS native extensions: panels, trust, management, policies, Responses SSE lifecycle')


if __name__ == '__main__':
    main()
