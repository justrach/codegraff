import { test, expect } from "bun:test";
import { mkdtempSync, writeFileSync, readFileSync, rmSync, readdirSync, realpathSync } from "node:fs";
import os from "node:os";
import path from "node:path";
import { NextRequest } from "next/server";
import { POST } from "../app/api/acp/route";

async function deadline<T>(operation: Promise<T>, label: string, ms = 3500): Promise<T> {
  let timer: ReturnType<typeof setTimeout> | undefined;
  try {
    return await Promise.race([operation, new Promise<never>((_, reject) => {
      timer = setTimeout(() => reject(new Error(`Fixture deadline: ${label}`)), ms);
    })]);
  } finally { clearTimeout(timer); }
}

test("a stuck cancelled ACP worker is replaced from its saved session before follow-up", async () => {
  const temp = mkdtempSync(path.join(os.tmpdir(), "graff-acp-route-"));
  const binary = path.join(temp, "agent.cjs");
  const oldBin = process.env.GRAFF_BIN;
  const oldConfig = process.env.__NEXT_PRIVATE_STANDALONE_CONFIG;
  // This executable speaks ACP only; no model, network, or real session files.
  writeFileSync(binary, `#!/usr/bin/env node
const fs = require('node:fs');
const path = require('node:path');
const readline = require('node:readline');
if (process.env.__NEXT_PRIVATE_STANDALONE_CONFIG) process.exit(2);
const previous = path.join(process.cwd(), 'pid');
if (fs.existsSync(previous)) {
  try { process.kill(Number(fs.readFileSync(previous)), 0); process.exit(3); } catch {}
}
fs.writeFileSync(previous, String(process.pid));
const resumed = process.argv.includes('--resume');
fs.appendFileSync('starts', JSON.stringify(process.argv.slice(2))+'\\n');
process.on('SIGTERM', () => {});
const send = value => console.log(JSON.stringify(value));
readline.createInterface({input:process.stdin}).on('line', line => {
  const req=JSON.parse(line);
  if(req.method==='initialize') send({id:req.id,result:{}});
  if(req.method==='session/new') {
    send({id:req.id,result:{sessionId:'saved-conversation'}});
    send({method:'session/update',params:{update:{sessionUpdate:'available_commands_update',availableCommands:[{name:'help'}]}}});
  }
  if(req.method==='session/prompt') {
    send({method:'session/update',params:{update:{sessionUpdate:'agent_message_chunk',content:{type:'text',text:resumed?'recovered':'started'}}}});
    if(resumed) send({id:req.id,result:{stopReason:'end_turn'}});
  }
}).on('close',()=>process.exit(0));
`, { mode: 0o700 });
  const chat = `route-test-${path.basename(temp)}`;
  const call = (method: string, params = {}) => deadline(POST(new NextRequest("http://localhost/api/acp", {
    method: "POST", body: JSON.stringify({ chat, method, params }),
  })), method, method === "session/cancel" ? 12000 : 3500);
  try {
    process.env.GRAFF_BIN = binary;
    process.env.__NEXT_PRIVATE_STANDALONE_CONFIG = "fixture";
    const initial = await call("bootstrap", { cwd: temp, model: "fixture", yolo: false, mcp: true });
    expect(initial.status).toBe(200);
    const first = await call("session/prompt", { prompt: [{ type: "text", text: "start" }] });
    const reader = first.body!.getReader();
    expect(new TextDecoder().decode((await deadline(reader.read(), "prompt readiness")).value)).toContain("gui_prompt_ready");
    expect(new TextDecoder().decode((await deadline(reader.read(), "response chunk")).value)).toContain("started");
    const ended = deadline(reader.read(), "cancel result", 12000);
    const cancelled = await call("session/cancel", { sessionId: "saved-conversation" });
    expect(cancelled.status).toBe(200);
    expect(new TextDecoder().decode((await ended).value)).toContain("interrupted worker stopped responding");
    expect((await deadline(reader.read(), "response chunk")).done).toBe(true);
    const next = await call("session/prompt", { prompt: [{ type: "text", text: "follow up" }] });
    expect(next.status).toBe(200);
    const text = await deadline(next.text(), "follow-up response");
    expect(text).toContain("recovered");
    expect(text).toContain('"stopReason":"end_turn"');
    const starts = readFileSync(path.join(temp, "starts"), "utf8").trim().split("\n").map(line => JSON.parse(line));
    expect(starts).toEqual([["acp", "--model", "fixture"], ["acp", "--model", "fixture", "--resume", "saved-conversation"]]);
  } finally {
    await call("dispose");
    if (oldBin === undefined) delete process.env.GRAFF_BIN; else process.env.GRAFF_BIN = oldBin;
    if (oldConfig === undefined) delete process.env.__NEXT_PRIVATE_STANDALONE_CONFIG; else process.env.__NEXT_PRIVATE_STANDALONE_CONFIG = oldConfig;
    rmSync(temp, { recursive: true, force: true });
  }
}, 20000);

test("an ACP error reaches a slow GUI reader intact and allows the next prompt", async () => {
  const temp = mkdtempSync(path.join(os.tmpdir(), "graff-acp-ending-"));
  const binary = path.join(temp, "agent.cjs");
  const oldBin = process.env.GRAFF_BIN;
  writeFileSync(binary, `#!/usr/bin/env node
const readline = require('node:readline');
const send = value => console.log(JSON.stringify(value));
let prompts = 0;
readline.createInterface({input:process.stdin}).on('line', line => {
  const req = JSON.parse(line);
  if(req.method==='initialize') send({id:req.id,result:{}});
  if(req.method==='session/new') {
    send({id:req.id,result:{sessionId:'fixture'}});
    send({method:'session/update',params:{update:{sessionUpdate:'available_commands_update',availableCommands:[]}}});
  }
  if(req.method==='session/prompt') {
    send({method:'session/update',params:{update:{sessionUpdate:'agent_message_chunk',content:{type:'text',text:'The preview is ready.'}}}});
    send(++prompts === 1 ? {id:req.id,error:{code:-32603,message:'Final inspection failed'}} : {id:req.id,result:{stopReason:'end_turn'}});
  }
}).on('close',()=>process.exit(0));
`, { mode: 0o700 });
  const chat = `ending-test-${path.basename(temp)}`;
  const call = (method: string, params = {}) => deadline(POST(new NextRequest("http://localhost/api/acp", {
    method: "POST", body: JSON.stringify({ chat, method, params }),
  })), method, method === "session/cancel" ? 12000 : 3500);
  try {
    process.env.GRAFF_BIN = binary;
    expect((await call("bootstrap", { cwd: temp, mcp: true })).status).toBe(200);
    const first = await call("session/prompt", { prompt: [{ type: "text", text: "start" }] });
    // Confirm the process has handled a later RPC before consuming the first
    // body: the old controller.error path discarded that buffered response.
    const until = Date.now() + 3500;
    let barrier = await call("initialize");
    for (let i = 0; barrier.status !== 200 && Date.now() < until && i < 100; i++) {
      await new Promise(resolve => setTimeout(resolve, 10));
      barrier = await call("initialize");
    }
    expect(barrier.status).toBe(200);
    const body = await deadline(first.text(), "first response");
    expect(body).toContain("The preview is ready.");
    expect(body).toContain('"message":"Final inspection failed"');
    expect(body).not.toContain('"stopReason":"end_turn"');
    const next = await call("session/prompt", { prompt: [{ type: "text", text: "continue" }] });
    expect(next.status).toBe(200);
    expect(await deadline(next.text(), "follow-up response")).toContain('"stopReason":"end_turn"');
  } finally {
    await call("dispose");
    if (oldBin === undefined) delete process.env.GRAFF_BIN; else process.env.GRAFF_BIN = oldBin;
    rmSync(temp, { recursive: true, force: true });
  }
}, 10000);

test("an older failed bootstrap cannot retire a newer chat worker", async () => {
  const temp = mkdtempSync(path.join(os.tmpdir(), "graff-acp-replacement-"));
  const binary = path.join(temp, "agent.cjs");
  const oldBin = process.env.GRAFF_BIN;
  writeFileSync(binary, `#!/usr/bin/env node
const fs=require('node:fs');
const stalled=process.argv.includes('stalled');
fs.appendFileSync('starts',String(process.pid)+'\\n');
const send=value=>console.log(JSON.stringify(value));
require('node:readline').createInterface({input:process.stdin}).on('line',line=>{
 const req=JSON.parse(line);
 if(req.method==='initialize') {
  if(stalled) fs.writeFileSync('stalled',String(process.pid));
  else send({id:req.id,result:{}});
 }
 if(req.method==='session/new') {
  send({id:req.id,result:{sessionId:'replacement'}});
  send({method:'session/update',params:{update:{sessionUpdate:'available_commands_update',availableCommands:[{name:'help'}]}}});
 }
}).on('close',()=>process.exit(0));
`, {mode:0o700});
  const chat = `replacement-test-${path.basename(temp)}`;
  const call = (method: string, params = {}) => deadline(POST(new NextRequest("http://localhost/api/acp", {
    method:"POST",body:JSON.stringify({chat,method,params}),
  })), method);
  try {
    process.env.GRAFF_BIN = binary;
    const older = call("bootstrap", {cwd:temp,model:"stalled",mcp:true});
    await deadline((async()=>{
      for(;;) {
        try { readFileSync(path.join(temp,"stalled")); return; } catch {}
        await new Promise(resolve=>setTimeout(resolve,10));
      }
    })(),"stalled child ready");
    const newer = await call("bootstrap", {cwd:temp,model:"replacement",mcp:true});
    expect(newer.status).toBe(200);
    const failed = await older;
    expect(failed.status).toBe(502);
    expect((await failed.json()).error).toContain("ACP startup failed during initialize");
    const reused = await call("bootstrap", {cwd:temp,model:"replacement",mcp:true});
    expect(reused.status).toBe(200);
    expect((await reused.json()).sessionId).toBe("replacement");
    expect((await call("initialize")).status).toBe(200);
    const started = readFileSync(path.join(temp,"starts"),"utf8").trim().split("\n").map(Number);
    expect(started.length).toBe(2);
    expect(()=>process.kill(started[0],0)).toThrow();
    expect(()=>process.kill(started[1],0)).not.toThrow();
  } finally {
    await call("dispose");
    if(oldBin===undefined)delete process.env.GRAFF_BIN;else process.env.GRAFF_BIN=oldBin;
    rmSync(temp,{recursive:true,force:true});
  }
},10000);


test("concurrent matching bootstraps finish one delayed worker handshake", async () => {
  const temp = mkdtempSync(path.join(os.tmpdir(), "graff-acp-concurrent-"));
  const binary = path.join(temp, "agent.cjs");
  const oldBin = process.env.GRAFF_BIN;
  writeFileSync(binary, `#!/usr/bin/env node
const fs = require('node:fs');
fs.appendFileSync('starts',String(process.pid)+'\\n');
const send=value=>console.log(JSON.stringify(value));
require('node:readline').createInterface({input:process.stdin}).on('line',line=>{
 const req=JSON.parse(line);
 if(req.method==='initialize') send({id:req.id,result:{}});
 if(req.method==='session/new') {
  fs.writeFileSync('initializing','yes');
  setTimeout(()=>{
   send({id:req.id,result:{sessionId:'shared'}});
   send({method:'session/update',params:{update:{sessionUpdate:'available_commands_update',availableCommands:[{name:'help'}]}}});
  },200);
 }
}).on('close',()=>process.exit(0));
`, {mode:0o700});
  const chat = `concurrent-test-${path.basename(temp)}`;
  const call = (method: string, params = {}) => deadline(POST(new NextRequest("http://localhost/api/acp", {
    method:"POST",body:JSON.stringify({chat,method,params}),
  })), method);
  try {
    process.env.GRAFF_BIN = binary;
    const options = {cwd:temp,model:"fixture",mcp:true};
    const startup = call("bootstrap", {...options, reset:true});
    await deadline((async()=>{
      for(;;) {
        try { readFileSync(path.join(temp,"initializing")); return; } catch {}
        await new Promise(resolve=>setTimeout(resolve,10));
      }
    })(),"worker initializing");
    const responses = await Promise.all([startup, call("bootstrap",options), call("bootstrap",options)]);
    for (const response of responses) {
      expect(response.status).toBe(200);
      expect((await response.json()).sessionId).toBe("shared");
    }
    expect(readFileSync(path.join(temp,"starts"),"utf8").trim().split("\n")).toHaveLength(1);
    expect((await call("initialize")).status).toBe(200);
  } finally {
    await call("dispose");
    if(oldBin===undefined)delete process.env.GRAFF_BIN;else process.env.GRAFF_BIN=oldBin;
    rmSync(temp,{recursive:true,force:true});
  }
},10000);

test("an idle worker is killed and the next prompt resumes the saved session", async () => {
  const temp = mkdtempSync(path.join(os.tmpdir(), "graff-acp-idle-"));
  const binary = path.join(temp, "agent.cjs");
  const oldBin = process.env.GRAFF_BIN;
  const oldIdle = process.env.GRAFF_ACP_IDLE_MS;
  writeFileSync(binary, `#!/usr/bin/env node
const fs=require('node:fs');
fs.writeFileSync('pid', String(process.pid));
fs.appendFileSync('starts', JSON.stringify(process.argv.slice(2))+'\\n');
const resumed=process.argv.includes('--resume');
const send=value=>console.log(JSON.stringify(value));
require('node:readline').createInterface({input:process.stdin}).on('line',line=>{
  const req=JSON.parse(line);
  if(req.method==='initialize') send({id:req.id,result:{}});
  if(req.method==='session/new') {
    send({id:req.id,result:{sessionId:'saved-conversation'}});
    send({method:'session/update',params:{update:{sessionUpdate:'available_commands_update',availableCommands:[]}}});
  }
  if(req.method==='session/prompt') {
    send({method:'session/update',params:{update:{sessionUpdate:'agent_message_chunk',content:{type:'text',text:resumed?'recovered':'started'}}}});
    send({id:req.id,result:{stopReason:'end_turn'}});
  }
}).on('close',()=>process.exit(0));
`, { mode: 0o700 });
  const chat = `idle-park-${path.basename(temp)}`;
  const call = (method: string, params = {}) => deadline(POST(new NextRequest("http://localhost/api/acp", {
    method: "POST", body: JSON.stringify({ chat, method, params }),
  })), method);
  try {
    process.env.GRAFF_BIN = binary;
    process.env.GRAFF_ACP_IDLE_MS = "40";
    expect((await call("bootstrap", { cwd: temp, model: "fixture", yolo: false, mcp: false })).status).toBe(200);
    const first = await call("session/prompt", { prompt: [{ type: "text", text: "start" }] });
    expect(await deadline(first.text(), "first turn")).toContain("started");
    const pid = Number(readFileSync(path.join(temp, "pid"), "utf8"));
    await new Promise(resolve => setTimeout(resolve, 120));
    expect(() => process.kill(pid, 0)).toThrow();
    const next = await call("session/prompt", { prompt: [{ type: "text", text: "again" }] });
    const text = await deadline(next.text(), "resumed turn");
    expect(text).toContain("recovered");
    const starts = readFileSync(path.join(temp, "starts"), "utf8").trim().split("\n").map(line => JSON.parse(line));
    expect(starts[0]).toEqual(["acp", "--model", "fixture"]);
    expect(starts[1]).toEqual(["acp", "--model", "fixture", "--resume", "saved-conversation"]);
  } finally {
    await call("dispose");
    if (oldBin === undefined) delete process.env.GRAFF_BIN; else process.env.GRAFF_BIN = oldBin;
    if (oldIdle === undefined) delete process.env.GRAFF_ACP_IDLE_MS; else process.env.GRAFF_ACP_IDLE_MS = oldIdle;
    rmSync(temp, { recursive: true, force: true });
  }
}, 15000);

test("a crashed ACP is resumed on the next prompt", async () => {
  const temp = mkdtempSync(path.join(os.tmpdir(), "graff-acp-crash-"));
  const binary = path.join(temp, "agent.cjs");
  const oldBin = process.env.GRAFF_BIN;
  const oldIdle = process.env.GRAFF_ACP_IDLE_MS;
  writeFileSync(binary, `#!/usr/bin/env node
const fs=require('node:fs');
fs.writeFileSync('pid', String(process.pid));
fs.appendFileSync('starts', JSON.stringify(process.argv.slice(2))+'\\n');
const resumed=process.argv.includes('--resume');
const send=value=>console.log(JSON.stringify(value));
require('node:readline').createInterface({input:process.stdin}).on('line',line=>{
  const req=JSON.parse(line);
  if(req.method==='initialize') send({id:req.id,result:{}});
  if(req.method==='session/new') {
    send({id:req.id,result:{sessionId:'saved-conversation'}});
    send({method:'session/update',params:{update:{sessionUpdate:'available_commands_update',availableCommands:[]}}});
  }
  if(req.method==='session/prompt') {
    send({method:'session/update',params:{update:{sessionUpdate:'agent_message_chunk',content:{type:'text',text:resumed?'recovered':'started'}}}});
    send({id:req.id,result:{stopReason:'end_turn'}});
  }
}).on('close',()=>process.exit(0));
`, { mode: 0o700 });
  const chat = `crash-resume-${path.basename(temp)}`;
  const call = (method: string, params = {}) => deadline(POST(new NextRequest("http://localhost/api/acp", {
    method: "POST", body: JSON.stringify({ chat, method, params }),
  })), method);
  try {
    process.env.GRAFF_BIN = binary;
    process.env.GRAFF_ACP_IDLE_MS = "0";
    expect((await call("bootstrap", { cwd: temp, model: "fixture", yolo: false, mcp: false })).status).toBe(200);
    const first = await call("session/prompt", { prompt: [{ type: "text", text: "start" }] });
    expect(await deadline(first.text(), "first turn")).toContain("started");
    const pid = Number(readFileSync(path.join(temp, "pid"), "utf8"));
    process.kill(pid, "SIGKILL");
    await deadline((async () => {
      while (true) {
        try { process.kill(pid, 0); } catch { return; }
        await new Promise(resolve => setTimeout(resolve, 10));
      }
    })(), "worker exit");
    await new Promise(resolve => setTimeout(resolve, 20));
    const next = await call("session/prompt", { prompt: [{ type: "text", text: "again" }] });
    expect(await deadline(next.text(), "resumed turn")).toContain("recovered");
    const starts = readFileSync(path.join(temp, "starts"), "utf8").trim().split("\n").map(line => JSON.parse(line));
    expect(starts[1]).toEqual(["acp", "--model", "fixture", "--resume", "saved-conversation"]);
  } finally {
    await call("dispose");
    if (oldBin === undefined) delete process.env.GRAFF_BIN; else process.env.GRAFF_BIN = oldBin;
    if (oldIdle === undefined) delete process.env.GRAFF_ACP_IDLE_MS; else process.env.GRAFF_ACP_IDLE_MS = oldIdle;
    rmSync(temp, { recursive: true, force: true });
  }
}, 15000);

test("closing a tab does not resume a parked worker", async () => {
  const temp = mkdtempSync(path.join(os.tmpdir(), "graff-acp-dispose-park-"));
  const binary = path.join(temp, "agent.cjs");
  const oldBin = process.env.GRAFF_BIN;
  const oldIdle = process.env.GRAFF_ACP_IDLE_MS;
  writeFileSync(binary, `#!/usr/bin/env node
const fs=require('node:fs');
fs.appendFileSync('starts', JSON.stringify(process.argv.slice(2))+'\\n');
const send=value=>console.log(JSON.stringify(value));
require('node:readline').createInterface({input:process.stdin}).on('line',line=>{
  const req=JSON.parse(line);
  if(req.method==='initialize') send({id:req.id,result:{}});
  if(req.method==='session/new') {
    send({id:req.id,result:{sessionId:'closed-tab'}});
    send({method:'session/update',params:{update:{sessionUpdate:'available_commands_update',availableCommands:[]}}});
  }
}).on('close',()=>process.exit(0));
`, { mode: 0o700 });
  const chat = `dispose-park-${path.basename(temp)}`;
  const call = (method: string, params = {}) => deadline(POST(new NextRequest("http://localhost/api/acp", {
    method: "POST", body: JSON.stringify({ chat, method, params }),
  })), method);
  try {
    process.env.GRAFF_BIN = binary;
    process.env.GRAFF_ACP_IDLE_MS = "40";
    expect((await call("bootstrap", { cwd: temp, model: "fixture", yolo: false, mcp: false })).status).toBe(200);
    expect((await call("dispose")).status).toBe(200);
    await new Promise(resolve => setTimeout(resolve, 80));
    expect((await call("bootstrap", { cwd: temp, model: "fixture", yolo: false, mcp: false })).status).toBe(200);
    const starts = readFileSync(path.join(temp, "starts"), "utf8").trim().split("\n").map(line => JSON.parse(line));
    expect(starts).toEqual([["acp", "--model", "fixture"], ["acp", "--model", "fixture"]]);
  } finally {
    await call("dispose");
    if (oldBin === undefined) delete process.env.GRAFF_BIN; else process.env.GRAFF_BIN = oldBin;
    if (oldIdle === undefined) delete process.env.GRAFF_ACP_IDLE_MS; else process.env.GRAFF_ACP_IDLE_MS = oldIdle;
    rmSync(temp, { recursive: true, force: true });
  }
}, 15000);

test("session/answer acknowledges the matching call_id and rejects empty or dead delivery", async () => {
  const temp = mkdtempSync(path.join(os.tmpdir(), "graff-acp-answer-"));
  const binary = path.join(temp, "agent.cjs");
  const oldBin = process.env.GRAFF_BIN;
  writeFileSync(binary, `#!/usr/bin/env node
const fs=require('node:fs');
const send=value=>console.log(JSON.stringify(value));
require('node:readline').createInterface({input:process.stdin}).on('line',line=>{
  const req=JSON.parse(line);
  if(req.method==='initialize') send({id:req.id,result:{}});
  if(req.method==='session/new') {
    send({id:req.id,result:{sessionId:'ask'}});
    send({method:'session/update',params:{update:{sessionUpdate:'available_commands_update',availableCommands:[]}}});
  }
  if(req.method==='session/answer') fs.appendFileSync('answers', JSON.stringify(req.params)+'\\n');
}).on('close',()=>process.exit(0));
`, { mode: 0o700 });
  const chat = `answer-${path.basename(temp)}`;
  const call = (method: string, params = {}) => deadline(POST(new NextRequest("http://localhost/api/acp", {
    method: "POST", body: JSON.stringify({ chat, method, params }),
  })), method);
  try {
    process.env.GRAFF_BIN = binary;
    expect((await call("bootstrap", { cwd: temp, model: "fixture", yolo: false, mcp: false })).status).toBe(200);
    const empty = await call("session/answer", { callId: "q1", text: "  " });
    expect(empty.status).toBe(400);
    expect(await empty.json()).toEqual({ error: "empty answer" });
    const first = await call("session/answer", { callId: "q1", text: "Mint" });
    expect(first.status).toBe(200);
    expect(await first.json()).toEqual({ ok: true, callId: "q1" });
    const repeat = await call("session/answer", { callId: "q1", text: "Mint" });
    expect(repeat.status).toBe(200);
    await new Promise(resolve => setTimeout(resolve, 40));
    const answers = readFileSync(path.join(temp, "answers"), "utf8").trim().split("\n").map(line => JSON.parse(line));
    expect(answers).toEqual([{ callId: "q1", text: "Mint", cancelled: false, sessionId: "ask" }]);
  } finally {
    await call("dispose");
    if (oldBin === undefined) delete process.env.GRAFF_BIN; else process.env.GRAFF_BIN = oldBin;
    rmSync(temp, { recursive: true, force: true });
  }
}, 15000);

test("ACP enrolls the requested workspace when session/new reports the host cwd", async () => {
  const temp = mkdtempSync(path.join(os.tmpdir(), "graff-acp-enroll-"));
  const isolated = path.join(temp, ".graff", "worktrees", "session-1");
  const binary = path.join(temp, "agent.cjs");
  const host = process.cwd();
  const oldBin = process.env.GRAFF_BIN;
  writeFileSync(binary, `#!/usr/bin/env node
const fs = require('node:fs');
fs.writeFileSync('spawn.env', JSON.stringify({ cwd: process.cwd(), pwd: process.env.PWD, graffCwd: process.env.GRAFF_CWD }));
const send = value => console.log(JSON.stringify(value));
require('node:readline').createInterface({input:process.stdin}).on('line', line => {
  const req = JSON.parse(line);
  if (req.method === 'initialize') send({id:req.id,result:{}});
  if (req.method === 'session/new') {
    const checkout = process.env.GRAFF_REPORT_CWD || ${JSON.stringify(host)};
    send({id:req.id,result:{sessionId:'enroll',cwd:checkout}});
    send({method:'session/update',params:{update:{sessionUpdate:'available_commands_update',availableCommands:[]}}});
  }
  if (req.method === 'session/prompt') send({id:req.id,result:{stopReason:'end_turn'}});
}).on('close',()=>process.exit(0));
`, { mode: 0o700 });
  const chat = `enroll-${path.basename(temp)}`;
  const call = (method: string, params = {}) => deadline(POST(new NextRequest("http://localhost/api/acp", {
    method: "POST", body: JSON.stringify({ chat, method, params }),
  })), method);
  const { attachmentStore } = await import("./attachment-store");
  try {
    process.env.GRAFF_BIN = binary;
    delete process.env.GRAFF_REPORT_CWD;
    const hostReport = await call("bootstrap", { cwd: temp, model: "fixture", yolo: false, mcp: false });
    expect(hostReport.status).toBe(200);
    expect(await hostReport.json()).toMatchObject({ sessionId: "enroll", cwd: path.resolve(temp) });
    const spawned = JSON.parse(readFileSync(path.join(temp, "spawn.env"), "utf8"));
    // process.cwd() is realpath; os.tmpdir() on macOS is /var → /private/var.
    expect(realpathSync(spawned.cwd)).toBe(realpathSync(temp));
    expect(realpathSync(spawned.pwd)).toBe(realpathSync(temp));
    expect(realpathSync(spawned.graffCwd)).toBe(realpathSync(temp));
    const store = attachmentStore();
    const image = store.create("enroll.png", new Uint8Array([1, 2, 3]));
    const prompted = await call("session/prompt", { prompt: [{ type: "text", text: `See @[${image}]` }] });
    expect(prompted.status).toBe(200);
    await deadline(prompted.text(), "image prompt");
    const scope = path.join(realpathSync(temp), ".graff", "sessions");
    const refs = path.join(store.directory, ".ownership", "references", path.basename(image));
    const scopes = readdirSync(refs).map(name => JSON.parse(readFileSync(path.join(refs, name), "utf8")).directory);
    expect(scopes).toEqual([scope]);
    process.env.GRAFF_REPORT_CWD = isolated;
    const tree = await call("bootstrap", { cwd: temp, model: "fixture", reset: true, yolo: false, mcp: false });
    expect(tree.status).toBe(200);
    expect(await tree.json()).toMatchObject({ sessionId: "enroll", cwd: isolated });
  } finally {
    await call("dispose");
    if (oldBin === undefined) delete process.env.GRAFF_BIN; else process.env.GRAFF_BIN = oldBin;
    delete process.env.GRAFF_REPORT_CWD;
    rmSync(temp, { recursive: true, force: true });
  }
}, 15000);
