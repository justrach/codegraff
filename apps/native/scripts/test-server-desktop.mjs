import {spawn,execFileSync} from 'node:child_process';
import {createRequire} from 'node:module';
import fs from 'node:fs';
import net from 'node:net';
import os from 'node:os';
import path from 'node:path';
import assert from 'node:assert/strict';
import {fileURLToPath} from 'node:url';
import {runDesktopProcess} from './test-electron.mjs';
const require=createRequire(import.meta.url),ui=path.resolve(path.dirname(fileURLToPath(import.meta.url)),'..'),repo=path.resolve(ui,'../..');
const binary=process.env.GRAFF_FRONTEND_BIN||path.join(repo,'zig-out/bin/graff');
const native=process.env.GRAFF_SHUTDOWN_NATIVE||path.join(repo,'zig-out/electron/Codegraff.app/Contents/Resources/native');
const output=path.resolve(process.env.GRAFF_SHUTDOWN_OUTPUT||path.join(repo,'zig-out/server-desktop'));
const sleep=ms=>new Promise(r=>setTimeout(r,ms));
const connects=port=>new Promise(resolve=>{const s=net.connect({host:'127.0.0.1',port});s.setTimeout(500);s.once('connect',()=>{s.destroy();resolve(true)});s.once('error',()=>resolve(false));s.once('timeout',()=>{s.destroy();resolve(false)});});
for(const pinned of [false,true]) {
 const temp=fs.mkdtempSync(path.join(os.tmpdir(),'graff-desktop-shutdown-')),out=path.join(output,pinned?'pinned':'automatic'),workspace=path.join(temp,'workspace'),resources=path.join(temp,'resources');
 for(const dir of [out,workspace,resources])fs.mkdirSync(dir,{recursive:true});
 fs.rmSync(path.join(out,'composer-clicks.jsonl'),{force:true});
 fs.cpSync(path.join(ui,'.next/standalone'),path.join(resources,'ui'),{recursive:true});
 fs.cpSync(path.join(ui,'electron'),path.join(resources,'app'),{recursive:true});
 fs.cpSync(path.join(ui,'.next/static'),path.join(resources,'ui/.next/static'),{recursive:true});
 const backendFile=path.join(resources,'ui/server.js');
 fs.writeFileSync(backendFile,`import {writeFileSync as recordBackendPid} from 'node:fs';recordBackendPid(${JSON.stringify(path.join(out,'backend-pid.txt'))},String(process.pid));\n`+fs.readFileSync(backendFile,'utf8'));
 fs.symlinkSync(native,path.join(resources,'native'));fs.symlinkSync(process.execPath,path.join(resources,'bun'));
 fs.writeFileSync(path.join(resources,'graff'),'#!/usr/bin/env python3\nimport os,sys\nbinary='+JSON.stringify(binary)+'\nargs=sys.argv[1:]\nif args and args[0]=="acp":args += ["--model","lmstudio","--old","--yolo"]\nos.execv(binary,[binary]+args)\n',{mode:0o755});
 fs.writeFileSync(path.join(workspace,'listener.py'),"import os,json,socket\nsocket.getfqdn=lambda *_: (_ for _ in ()).throw(RuntimeError('unexpected hostname lookup'))\nfrom pathlib import Path\nfrom http.server import HTTPServer,BaseHTTPRequestHandler\nfrom socketserver import TCPServer\nclass NumericHTTPServer(HTTPServer):\n def server_bind(self):\n  TCPServer.server_bind(self)\n  self.server_name,self.server_port=self.server_address[:2]\nclass Handler(BaseHTTPRequestHandler):\n def do_GET(self):\n  print('request served',flush=True)\n  self.send_response(200);self.end_headers();self.wfile.write(b'ready')\ns=NumericHTTPServer(('127.0.0.1',0),Handler)\nPath('listener.json').write_text(json.dumps({'pid':os.getpid(),'port':s.server_port}))\ns.serve_forever()\n");
 fs.writeFileSync(path.join(workspace,'ready.py'),"import json,time,urllib.request\nfrom pathlib import Path\nfor _ in range(100):\n if Path('listener.json').exists():break\n time.sleep(.05)\nr=json.loads(Path('listener.json').read_text());body=urllib.request.urlopen('http://127.0.0.1:'+str(r['port']),timeout=2).read();assert body==b'ready',body;print('HTTP response verified: ready')\n");
 const script=path.join(temp,'script.json'),mcp=path.join(temp,'mcp.json');fs.writeFileSync(mcp,'{"mcpServers":{}}');fs.writeFileSync(script,JSON.stringify([{tool:'bash',arguments:{command:'python3 listener.py',run_in_background:true}},{tool:'bash',arguments:{command:'python3 ready.py'}},{text:'Listener ready for shutdown.'}]));
 const env={...process.env,HOME:temp,LMSTUDIO_API_KEY:'local',GRAFF_CWD:workspace,GRAFF_ELECTRON_RESOURCES:resources,GRAFF_ELECTRON_SMOKE:path.join(out,'smoke.json'),GRAFF_SMOKE_SERVER_LIFECYCLE:'1',GRAFF_SHUTDOWN_OUTPUT:out,GRAFF_SHUTDOWN_PIN:pinned?'1':'0',GRAFF_SHUTDOWN_SKIP_FIRST_COMPOSER_CLICK:pinned?'1':'0',GRAFF_SMOKE_PROFILE:path.join(temp,'profile'),GRAFF_MCP_CONFIG:mcp,GRAFF_NO_TELEMETRY:'1',GRAFF_FLEET:'off',GRAFF_NO_SMOLIFY:'1',GRAFF_NO_CODEDB_GUARD:'1',GRAFF_AUTO_ISOLATE:'0',GRAFF_TEST_TIMEOUT_MS:process.env.GRAFF_TEST_TIMEOUT_MS||'180000'};
 for(const key of Object.keys(env))if(key.endsWith('_API_KEY')&&key!=='LMSTUDIO_API_KEY')delete env[key];
 const fd=fs.openSync(path.join(out,'model.log'),'w'),model=spawn('python3',[path.join(repo,'scripts/eval/frontend_model.py'),'--script',script,'--requests',path.join(out,'requests.json')],{env,stdio:['ignore',fd,fd]});fs.closeSync(fd);
 const unrelated=net.createServer(s=>s.end());await new Promise(r=>unrelated.listen(0,'127.0.0.1',r));
 try {
  const end=Date.now()+10000;while(!fs.readFileSync(path.join(out,'model.log'),'utf8').includes('scripted model on')){assert(model.exitCode===null&&Date.now()<end,'fixture unavailable');await sleep(50)}
  process.env.GRAFF_TEST_TIMEOUT_MS=env.GRAFF_TEST_TIMEOUT_MS;
  assert.equal(await runDesktopProcess(require('electron'),[path.join(ui,'electron/server-lifecycle-entry.cjs')],env),0,'Electron fixture failed');
  const composerClicks=fs.readFileSync(path.join(out,'composer-clicks.jsonl'),'utf8').trim().split('\n').flatMap(line=>JSON.parse(line));
  assert(composerClicks.at(-1)?.down && composerClicks.at(-1)?.click && composerClicks.at(-1)?.focused,'trusted composer click was not observed');
  if(pinned)assert(composerClicks.some(row=>!row.down&&!row.click),'missed composer click did not exercise recovery');
  const replies=JSON.parse(fs.readFileSync(path.join(out,'requests.json'),'utf8')).flatMap(request=>request.messages||[]);
  assert(replies.some(message=>message.role==='tool'&&message.content==='HTTP response verified: ready\n'),'agent did not observe a successful HTTP check');
  const before=JSON.parse(fs.readFileSync(path.join(out,'before-quit.json'),'utf8'));
  assert.deepEqual(JSON.parse(fs.readFileSync(path.join(out,'quit-observed.json'),'utf8')),{backendGone:true,workerGone:true});
  assert(await connects(before.listener.port),'listener lost during quit');
  const response=await fetch(`http://127.0.0.1:${before.listener.port}`,{signal:AbortSignal.timeout(2000)});
  const responseText=await response.text();assert.equal(response.status,200);assert.equal(responseText,'ready');
  fs.writeFileSync(path.join(out,'after-response.txt'),responseText);
  const rec=JSON.parse(fs.readFileSync(path.join(temp,'.codegraff/jobs',`${before.record.pid}.json`),'utf8'));assert.equal(rec.pinned,pinned);assert.equal(rec.retained,true);assert.equal(rec.retention_reason,pinned?'user_pin':'unverified_consumers');
  const listing=execFileSync(binary,['servers','list'],{env,cwd:workspace,encoding:'utf8',timeout:30000});fs.writeFileSync(path.join(out,'after-list.txt'),listing);
  const row=listing.split('\n').find(l=>l.trim().split(/\s+/)[0].replace(/^\+/,'')===String(before.record.pid));assert(row?.includes('gone'),listing);
  fs.writeFileSync(path.join(out,'stop.txt'),execFileSync(binary,['servers','stop',String(before.record.pid)],{env,cwd:workspace,encoding:'utf8',timeout:30000}));
  assert(!await connects(before.listener.port),'verified stop left listener open');assert(await connects(unrelated.address().port),'unrelated listener lost');
  fs.writeFileSync(path.join(out,'results.json'),JSON.stringify({status:'passed',pinned,desktopQuitObserved:true,listenerSurvived:true,verifiedStopClosed:true,unrelatedSurvived:true},null,2));console.log(`PASS desktop quit: pinned=${pinned}`);
 } finally {
  const registry=path.join(temp,'.codegraff/jobs');
  if(fs.existsSync(registry))for(const file of fs.readdirSync(registry)){
    try {const record=JSON.parse(fs.readFileSync(path.join(registry,file),'utf8'));execFileSync(binary,['servers','stop',String(record.pid)],{env,cwd:workspace,timeout:10000,stdio:'ignore'});}catch{}
  }
  const backendPidFile=path.join(out,'backend-pid.txt');
  if(fs.existsSync(backendPidFile)){
    const pid=Number(fs.readFileSync(backendPidFile,'utf8'));
    try {
      const snapshot=execFileSync('ps',['-p',String(pid),'-o','pgid=,command='],{encoding:'utf8'}).trim();
      if(snapshot.split(/\s+/)[0]===String(pid)&&snapshot.includes(path.join(resources,'ui/server.js')))process.kill(-pid,'SIGTERM');
    } catch {}
  }
  if(fs.existsSync(path.join(workspace,'.graff')))fs.cpSync(path.join(workspace,'.graff'),path.join(out,'graff'),{recursive:true});
  const logs=path.join(temp,'profile/logs');if(fs.existsSync(logs))fs.cpSync(logs,path.join(out,'logs'),{recursive:true});
  model.kill('SIGTERM');
  const death=Date.now()+5000;while(model.exitCode===null&&Date.now()<death)await sleep(50);
  if(model.exitCode===null)model.kill('SIGKILL');
  unrelated.close();fs.rmSync(temp,{recursive:true,force:true});
 }
}
