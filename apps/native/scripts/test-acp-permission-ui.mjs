/** Real browser -> desktop route -> real ACP -> offline model permission proof. */
import { mkdtempSync, writeFileSync, existsSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { NextRequest } from "next/server";
import { chromium } from "playwright";
import { POST } from "../app/api/acp/route";
const temp = mkdtempSync(path.join(tmpdir(), "acp-permission-ui-"));
const binary = path.resolve(process.argv[2]);
const native = path.resolve(import.meta.dir, "..");
const repo = path.resolve(native, "../..");
const script = path.join(temp, "model.json");
writeFileSync(script, JSON.stringify([{tool:"bash",arguments:{command:"python3 -c \"open('approved.txt','w').write('approved')\""}},{text:"Approved command completed."}]));
const model = Bun.spawn(["python3",path.join(repo,"scripts/eval/mock_model.py"),"--script",script,"--port","0"],{stdout:"pipe",stderr:"inherit"});
const reader = model.stdout.getReader();
let startup = "";
while (!startup.includes("\n")) { const chunk = await reader.read(); if (chunk.done) break; startup += new TextDecoder().decode(chunk.value); }
reader.releaseLock();
const port = startup.match(/127\.0\.0\.1:(\d+)/)?.[1];
if (!port) { model.kill(); throw new Error("Mock provider did not report its port"); }
const oldEnv = {...process.env};
for(const key of Object.keys(process.env)) if(key.endsWith("_API_KEY")) delete process.env[key];
Object.assign(process.env,{HOME:temp,GRAFF_BIN:binary,AI_GATEWAY_API_KEY:"local",GRAFF_VERCEL_URL:`http://127.0.0.1:${port}/v1/chat/completions`,GRAFF_NO_TELEMETRY:"1",GRAFF_FLEET:"off",GRAFF_NO_SMOLIFY:"1",GRAFF_NO_CODEDB_GUARD:"1"});
const entry = path.join(native,".permission-ui-fixture.tsx");
writeFileSync(entry, `import React,{useEffect,useState} from 'react';import{createRoot}from'react-dom/client';import{useAcpPermissions}from'./components/site/useAcpPermissions';import{prompt}from'./lib/acp-client';function App(){const permissions=useAcpPermissions(()=>"permission-ui");const[done,setDone]=useState(false);useEffect(()=>{(async()=>{const r=await fetch('/api/acp',{method:'POST',headers:{'content-type':'application/json'},body:JSON.stringify({chat:'permission-ui',method:'bootstrap',params:{cwd:${JSON.stringify(temp)},model:'vercel',yolo:false,mcp:false}})});const s=await r.json();for await(const u of prompt('permission-ui',s.sessionId,'Execute the fixture command.')){if(u.sessionUpdate==='gui_permission')permissions.update(1,u.permission as any);}setDone(true);})().catch(e=>document.body.dataset.error=String(e));},[]);return <>{permissions.dialog}<p>{done?'Completed':'Running'}</p></>}createRoot(document.getElementById('root')!).render(<App/>);`);
let server;
let browser;
try {
 const build=await Bun.build({entrypoints:[entry],target:"browser",define:{"process.env.NODE_ENV":JSON.stringify("production")}});
 if(!build.success)throw new Error(String(build.logs));
 const javascript=await build.outputs[0].text();
 server=Bun.serve({port:0,fetch:async request=>new URL(request.url).pathname==='/api/acp'?POST(new NextRequest(request)):new Response(new URL(request.url).pathname==='/app.js'?javascript:'<div id="root"></div><script src="/app.js"></script>',{headers:{'content-type':new URL(request.url).pathname==='/app.js'?'text/javascript':'text/html'}})});
 browser=await chromium.launch({headless:true});const page=await browser.newPage();await page.goto(server.url.toString());
 await page.getByRole('dialog',{name:'Tool permission'}).waitFor({timeout:30000});
 if(existsSync(path.join(temp,'approved.txt')))throw new Error('Command ran before browser approval');
 await page.getByRole('button',{name:'Allow once',exact:true}).click();
 await page.getByText('Completed',{exact:true}).waitFor({timeout:30000});
 if(readFileSync(path.join(temp,'approved.txt'),'utf8')!=='approved')throw new Error('Approved command missing');
 if(await page.getByRole('dialog').count())throw new Error('Permission remained after acknowledgement');
 console.log('PASS browser permission: explicit click -> HTTP route -> ACP reply -> command execution');
} finally {
 await browser?.close();
 await POST(new NextRequest('http://localhost/api/acp',{method:'POST',body:JSON.stringify({chat:'permission-ui',method:'dispose'})}));
 server?.stop(true);model.kill();await model.exited;
 rmSync(entry,{force:true});rmSync(temp,{recursive:true,force:true});
 for(const key of Object.keys(process.env))if(!(key in oldEnv))delete process.env[key];Object.assign(process.env,oldEnv);
}
