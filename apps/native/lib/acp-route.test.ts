import { test, expect } from "bun:test";
import { mkdtempSync, writeFileSync, readFileSync, rmSync } from "node:fs";
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
