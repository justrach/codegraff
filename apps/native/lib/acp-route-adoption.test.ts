import { expect, test } from "bun:test";
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import os from "node:os";
import path from "node:path";
import { NextRequest } from "next/server";
import { POST } from "../app/api/acp/route";

async function until(ready: () => boolean) {
  const end = Date.now() + 3500;
  while (!ready()) {
    if (Date.now() > end) throw new Error("Bootstrap fixture readiness timed out");
    await new Promise(resolve => setTimeout(resolve, 10));
  }
}

for (const outcome of ["replacement", "failure", "dispose"] as const) {
  test(`queued bootstrap callers share the final ${outcome} outcome`, async () => {
    const temp = mkdtempSync(path.join(os.tmpdir(), "graff-acp-adoption-"));
    const binary = path.join(temp, "agent.cjs");
    const oldBin = process.env.GRAFF_BIN;
    writeFileSync(binary, `#!/usr/bin/env node
const fs = require('node:fs');
const stalled = process.argv.includes('stalled');
const failed = process.argv.includes('failure');
fs.appendFileSync('starts', String(process.pid) + '\\n');
const send = value => console.log(JSON.stringify(value));
require('node:readline').createInterface({input:process.stdin}).on('line', line => {
  const req = JSON.parse(line);
  if (req.method === 'initialize') {
    if (stalled) fs.writeFileSync('stalled', String(process.pid));
    else if (failed) send({id:req.id,error:{code:-32603,message:'final bootstrap failure'}});
    else send({id:req.id,result:{protocolVersion:1}});
  }
  if (req.method === 'session/new') {
    send({id:req.id,result:{sessionId:'replacement'}});
    send({method:'session/update',params:{update:{sessionUpdate:'available_commands_update',availableCommands:[]}}});
  }
}).on('close', () => process.exit(0));
`, { mode: 0o700 });
    const chat = `adoption-${path.basename(temp)}`;
    const pending = (globalThis as typeof globalThis & { __graffAcpBootstraps: Map<string, Promise<unknown>> }).__graffAcpBootstraps;
    const call = (method: string, params = {}) => POST(new NextRequest("http://localhost/api/acp", {
      method: "POST", body: JSON.stringify({ chat, method, params }),
    }));
    const starts = () => readFileSync(path.join(temp, "starts"), "utf8").trim().split("\n").map(Number);
    try {
      process.env.GRAFF_BIN = binary;
      const original = call("bootstrap", { cwd: temp, model: "stalled", mcp: true });
      await until(() => { try { return !!readFileSync(path.join(temp, "stalled")); } catch { return false; } });
      const first = pending.get(chat);
      const queued = call("bootstrap");
      await until(() => pending.get(chat) !== first);
      const last = outcome === "dispose"
        ? call("dispose")
        : call("bootstrap", { cwd: temp, model: outcome, mcp: true });
      const [a, a2, b] = await Promise.all([original, queued, last]);
      if (outcome === "replacement") {
        for (const response of [a, a2, b]) {
          expect(response.status).toBe(200);
          expect((await response.json()).sessionId).toBe("replacement");
        }
        expect(starts().length).toBe(2);
        expect(() => process.kill(starts()[0], 0)).toThrow();
        expect(() => process.kill(starts()[1], 0)).not.toThrow();
        expect((await call("bootstrap", { cwd: temp, model: "replacement", mcp: true })).status).toBe(200);
        expect(starts().length).toBe(2);
      } else {
        for (const response of outcome === "failure" ? [a, a2, b] : [a, a2]) {
          expect(response.status).toBe(502);
          const error = (await response.json()).error as string;
          expect(error).toContain(outcome === "failure" ? "final bootstrap failure" : "worker retired");
          if (outcome === "failure") expect(error).not.toContain("worker retired");
        }
        if (outcome === "dispose") expect(b.status).toBe(200);
        for (const pid of starts()) expect(() => process.kill(pid, 0)).toThrow();
        expect((await call("bootstrap", { cwd: temp, model: "replacement", mcp: true })).status).toBe(200);
      }
      expect(pending.has(chat)).toBe(false);
    } finally {
      await call("dispose");
      if (oldBin === undefined) delete process.env.GRAFF_BIN; else process.env.GRAFF_BIN = oldBin;
      for (const pid of starts()) expect(() => process.kill(pid, 0)).toThrow();
      rmSync(temp, { recursive: true, force: true });
    }
  }, 10000);
}
