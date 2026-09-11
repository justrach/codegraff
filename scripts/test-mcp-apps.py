#!/usr/bin/env python3
"""Offline engine integration: MCP metadata -> bounded snapshot -> model-safe text."""
import base64
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

sys.path.insert(0, str(Path(__file__).parent / "eval"))
from mock_model import ScriptedModel

VIEW = """<!doctype html><h1>Fixture app</h1><div id="result"></div><button id="open">Open source</button><button id="tool">Try tool</button><script>
parent.postMessage({jsonrpc:'2.0',id:1,method:'ui/initialize',params:{protocolVersion:'2026-01-26',appInfo:{name:'Fixture',version:'1'},appCapabilities:{}}},'*');
onmessage=e=>{const m=e.data;if(m.id===1&&m.result)parent.postMessage({jsonrpc:'2.0',method:'ui/notifications/initialized',params:{}},'*');if(m.method==='ui/notifications/tool-result')document.querySelector('#result').textContent=m.params.structuredContent.title;if(m.id===3)document.querySelector('#result').textContent=m.error?'Tool blocked':'Unexpected execution';};
document.querySelector('#open').onclick=()=>parent.postMessage({jsonrpc:'2.0',id:2,method:'ui/open-link',params:{url:'https://example.com/design'}},'*');
document.querySelector('#tool').onclick=()=>parent.postMessage({jsonrpc:'2.0',id:3,method:'tools/call',params:{name:'write_file'}},'*');
</script>"""

class Fixture(BaseHTTPRequestHandler):
    def log_message(self, *_): pass
    methods = []
    mode = "text"
    def do_POST(self):
        msg = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
        method = msg['method']; self.methods.append(method)
        if method == 'tools/list':
            result = {'tools':[{'name':'show','description':'Show a fixture app','inputSchema':{'type':'object','properties':{}},'_meta':{'ui':{'resourceUri':'ui://fixture/view'}}}]}
        elif method == 'initialize':
            result = {'protocolVersion':'2025-03-26','capabilities':{'tools':{},'resources':{}},'serverInfo':{'name':'fixture','version':'1'}}
        elif method == 'tools/call':
            result = {'content':[{'type':'text','text':'Public fixture answer'}],'structuredContent':{'title':'Rendered fixture result'},'_meta':{'privateViewField':'not-for-model'}}
        elif method == 'resources/read':
            resource = {'uri':'ui://fixture/view','mimeType':'text/html;profile=mcp-app'}
            if self.mode == 'blob': resource['blob'] = base64.b64encode(VIEW.encode()).decode()
            else: resource['text'] = VIEW
            if self.mode == 'invalid-mime': resource['mimeType'] = 'text/html'
            result = {'contents':[resource]}
        else: result = {}
        body = json.dumps({'jsonrpc':'2.0','id':msg.get('id'),'result':result}).encode()
        self.send_response(200);self.send_header('Content-Type','application/json');self.send_header('Content-Length',str(len(body)));self.end_headers();self.wfile.write(body)

def run_case(graff, mode):
    Fixture.mode=mode; Fixture.methods=[]
    server=ThreadingHTTPServer(('127.0.0.1',0),Fixture);threading.Thread(target=server.serve_forever,daemon=True).start()
    model=ScriptedModel([{'tool':'load_tool_schemas','arguments':{'server':'fixture'}},{'tool':'mcp__fixture__show','arguments':{}},{'text':'Fixture complete.'}]);model.start(1234)
    artifact=None
    try:
        with tempfile.TemporaryDirectory(prefix='graff-app-fixture-') as temp:
            root=Path(temp);(root/'.mcp.json').write_text(json.dumps({'mcpServers':{'fixture':{'url':f'http://127.0.0.1:{server.server_port}/mcp'}}}))
            (root/'empty.json').write_text((root/'.mcp.json').read_text())
            (root/'.harness').mkdir();(root/'.harness/settings.json').write_text('{"skills":{"codedbpro":false,"muonry":false}}')
            env={k:v for k,v in os.environ.items() if not k.endswith('_API_KEY')}
            env.update(LMSTUDIO_API_KEY='local',GRAFF_MCP_CONFIG=str(root/'empty.json'),GRAFF_NO_TELEMETRY='1',GRAFF_FLEET='off',GRAFF_NO_SMOLIFY='1',GRAFF_NO_CODEDB_GUARD='1',GRAFF_BEHAVIOR_TRACE='0')
            run=subprocess.run([str(graff),'--json','--yolo','--old','--model','lmstudio'],input=json.dumps({'type':'user','text':'Call mcp__fixture__show, then finish.'})+'\n',cwd=root,env=env,text=True,capture_output=True,timeout=60)
            assert run.returncode==0, run.stderr[-2000:]
            match=re.search(r'\[MCP app\]\(([^\r\n]*?/\.graff/mcp-apps/[a-f0-9]{32}\.html)\)',run.stdout)
            if mode == 'invalid-mime':
                assert match is None
                assert 'MCP app view unavailable' in run.stdout
                assert 'Public fixture answer' in run.stdout
                print('PASS engine: invalid resource MIME falls back to ordinary result')
                return
            assert match, 'App marker absent: '+run.stdout[-3000:]
            artifact=Path(match.group(1));html=artifact.read_text();payload=re.search(r"atob\('([A-Za-z0-9+/=]+)'\)",html).group(1)
            saved=json.loads(base64.b64decode(payload));assert saved['resource']['text']==VIEW
            assert saved['result']['structuredContent']['title']=='Rendered fixture result'
            assert saved['result']['_meta']['privateViewField']=='not-for-model'
            assert artifact.stat().st_mode & 0o777 == 0o600
            assert 'resources/read' in Fixture.methods
            assert 'not-for-model' not in json.dumps(model.requests)
            assert '<h1>Fixture app</h1>' not in json.dumps(model.requests)
            Path('/tmp/graff-mcp-app-fixture.html').write_text(html)
            print(f'PASS engine ({mode}): UI resource fetched, result preserved, private metadata excluded from model, snapshot mode 0600')
    finally:
        if artifact: artifact.unlink(missing_ok=True)
        server.shutdown();server.server_close();model.stop()

if __name__=='__main__':
    graff=Path(sys.argv[1] if len(sys.argv)>1 else 'zig-out/bin/graff').resolve()
    for mode in ('text','blob','invalid-mime'): run_case(graff,mode)
