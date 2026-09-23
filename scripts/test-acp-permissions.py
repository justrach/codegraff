#!/usr/bin/env python3
"""Offline real ACP permission decisions, persistence and cancellation."""
import json, os, queue, signal, subprocess, sys, tempfile, threading, time
from pathlib import Path
sys.path.insert(0,str(Path(__file__).resolve().parent/'eval'))
from mock_model import ScriptedModel

def run(binary,decision):
    command="python3 -c \"open('approved.txt','a').write('yes')\""
    script=[{'tool':'bash','arguments':{'command':command}}, {'tool':'bash','arguments':{'command':command}}, {'text':'Done.'}]
    model=ScriptedModel(script)
    with tempfile.TemporaryDirectory(prefix='acp-permissions-') as temp:
        env={k:v for k,v in os.environ.items() if not k.endswith('_API_KEY')}
        config=Path(temp)/'mcp.json';config.write_text('{"mcpServers":{}}')
        env.update(HOME=temp,AI_GATEWAY_API_KEY='local',GRAFF_MCP_CONFIG=str(config),GRAFF_NO_TELEMETRY='1',GRAFF_FLEET='off',GRAFF_NO_SMOLIFY='1',GRAFF_NO_CODEDB_GUARD='1')
        port = model.start(0)
        env['GRAFF_VERCEL_URL'] = f'http://127.0.0.1:{port}/v1/chat/completions'
        proc=subprocess.Popen([binary,'acp','--model','vercel','--old','--no-lean'] + (['--yolo'] if decision=='yolo' else []),cwd=temp,env=env,stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.DEVNULL,text=True,start_new_session=True)
        messages=queue.Queue()
        def read():
            for line in proc.stdout:
                try:messages.put(json.loads(line))
                except ValueError:pass
            messages.put(None)
        threading.Thread(target=read,daemon=True).start()
        def send(obj):proc.stdin.write(json.dumps({'jsonrpc':'2.0',**obj})+'\n');proc.stdin.flush()
        def wait(id,respond=False):
            requests=[]; deadline=time.monotonic()+30
            while True:
                m=messages.get(timeout=max(.01,deadline-time.monotonic()));assert m is not None,'worker exited'
                if m.get('id')==id:return m,requests
                if m.get('method')=='session/request_permission':
                    assert respond,m
                    assert not (Path(temp)/'approved.txt').exists() or requests, 'tool executed before approval'
                    requests.append(m)
                    if decision=='cancel':send({'method':'session/cancel','params':{'sessionId':sid}});continue
                    # Stale ID cannot grant the active request.
                    send({'id':'graff-permission-0','result':{'outcome':{'outcome':'selected','optionId':'allow_always'}}})
                    outcome={'outcome':'cancelled'} if decision=='dismiss' else {'outcome':'selected','optionId':decision}
                    send({'id':m['id'],'result':{'outcome':outcome}})
        try:
            send({'id':1,'method':'initialize','params':{'protocolVersion':1}});wait(1)
            send({'id':2,'method':'session/new','params':{'cwd':temp,'mcpServers':[]}});result,_=wait(2);sid=result['result']['sessionId']
            send({'id':3,'method':'session/prompt','params':{'sessionId':sid,'prompt':[{'type':'text','text':'Run the scripted fixture.'}]}})
            result,requests=wait(3,True)
            assert bool(requests) == (decision != 'yolo'), 'unexpected permission count'
            content=(Path(temp)/'approved.txt').read_text() if (Path(temp)/'approved.txt').exists() else ''
            if decision=='yolo':assert not requests and content=='yesyes',(requests,content)
            elif decision=='allow_always':assert len(requests)==1 and content=='yesyes',(requests,content)
            elif decision=='allow_once':assert len(requests)==2 and content=='yesyes',(requests,content)
            else:assert content=='',content
            if decision=='cancel':assert result.get('result',{}).get('stopReason')=='cancelled',result
            print('PASS ACP permission',decision,'requests',len(requests),flush=True)
        finally:
            os.killpg(proc.pid,signal.SIGKILL);proc.wait(timeout=3);model.stop()

if __name__=='__main__':
    binary=str(Path(sys.argv[1]).resolve())
    for decision in ['allow_once','allow_always','reject_once','dismiss','cancel','yolo']:run(binary,decision)
