#!/usr/bin/env python3
"""Real ACP worker: tool result, provider failure, saved result and follow-up.
Local scripted provider only; every read and process teardown is bounded.
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
sys.path.insert(0, str(Path(__file__).resolve().parent / 'eval'))
from mock_model import ScriptedModel


def main():
    binary = str(Path(sys.argv[1] if len(sys.argv) > 1 else 'zig-out/bin/graff').resolve())
    model = ScriptedModel([
        {'tool':'bash','arguments':{'command':'printf kept > proof.txt'}},
        {'http_status':400,'error':'Scripted final request rejected'},
        {'tool':'bash','arguments':{'command':'cat proof.txt'}},
        {'text':'The earlier result is still present.'},
    ])
    with tempfile.TemporaryDirectory(prefix='graff-acp-failure-') as temp:
        env = {k:v for k,v in os.environ.items() if not k.endswith('_API_KEY')}
        config = Path(temp)/'mcp.json'; config.write_text('{"mcpServers":{}}')
        env.update(HOME=temp,LMSTUDIO_API_KEY='local',GRAFF_MCP_CONFIG=str(config),GRAFF_NO_TELEMETRY='1',GRAFF_FLEET='off',GRAFF_NO_SMOLIFY='1',GRAFF_NO_CODEDB_GUARD='1')
        model.start(1234)
        proc = None
        try:
            proc = subprocess.Popen([binary,'acp','--model','lmstudio','--yolo'],cwd=temp,env=env,stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.DEVNULL,text=True,start_new_session=True)
            events = queue.Queue()
            def reader():
                for line in proc.stdout:
                    try: events.put(json.loads(line))
                    except ValueError: pass
                events.put(None)
            threading.Thread(target=reader,daemon=True).start()
            def call(method,params,id):
                proc.stdin.write(json.dumps(dict(jsonrpc='2.0',method=method,params=params,id=id))+'\n');proc.stdin.flush()
                deadline = time.monotonic()+25
                updates=[]
                while True:
                    value=events.get(timeout=max(.01,deadline-time.monotonic()))
                    assert value is not None, 'ACP worker exited before replying'
                    if value.get('id')==id: return value,updates
                    updates.append(value)
            call('initialize',{'protocolVersion':1},1)
            session,_=call('session/new',{},2);sid=session['result']['sessionId']
            def prompt(text,id): return call('session/prompt',{'sessionId':sid,'prompt':[{'type':'text','text':text}]},id)
            failure,updates=prompt('Write the fixture file, then finish.',3)
            assert 'error' in failure and 'Scripted final request rejected' in failure['error']['message'], failure
            assert any(e.get('params',{}).get('update',{}).get('status')=='completed' for e in updates), updates
            assert (Path(temp)/'proof.txt').read_text()=='kept'
            saved=list((Path(temp)/'.graff/sessions').glob('*.session.json'))
            assert saved and any('proof.txt' in p.read_text() for p in saved), 'Tool work was not saved'
            result,_=prompt('Read the fixture file and report its state.',4)
            assert result.get('result',{}).get('stopReason')=='end_turn',result
            assert 'kept' in json.dumps(model.requests[-1]), 'Follow-up did not receive the original result'
            print('PASS ACP failure: explicit error, completed tool retained, saved history, live follow-up succeeds')
        finally:
            if proc:
                try: os.killpg(proc.pid,signal.SIGKILL)
                except ProcessLookupError: pass
                proc.wait(timeout=2)
                for pipe in (proc.stdin,proc.stdout):
                    if pipe: pipe.close()
            model.stop()

if __name__=='__main__': main()
