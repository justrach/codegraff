import { test, expect } from "bun:test";
import { spawn } from "node:child_process";
import { once } from "node:events";
import { AcpTransport } from "./acp-transport";
import { initializeWorker } from "./acp-bootstrap";
import { retireWorker } from "./acp-retire";

async function worker(mode: string) {
  const child = spawn(process.execPath, ["-e", `
    const mode = ${JSON.stringify(mode)};
    const send = value => console.log(JSON.stringify(value));
    require('node:readline').createInterface({input:process.stdin}).on('line', line => {
      const req=JSON.parse(line);
      if(req.method==='initialize' && mode!=='initialize') send({id:req.id,result:{}});
      if(req.method==='session/new' && mode!=='session/new') send({id:req.id,result:mode==='invalid'?{}:{sessionId:'ready'}});
    });
    console.log('ready');
  `], { stdio: ["pipe", "pipe", "inherit"] });
  const transport = new AcpTransport(child);
  await once(child.stdout, "data");
  return { child, transport };
}

for (const mode of ["initialize", "session/new", "invalid"]) {
  test(`failed ACP ${mode} retires its child and a fresh worker succeeds`, async () => {
    const failed = await worker(mode);
    let retired = false;
    try {
      await expect(initializeWorker(failed.transport, process.cwd(), async () => {
        await retireWorker(failed.child, 50); retired = true;
      }, 50)).rejects.toThrow(`ACP startup failed during ${mode==='invalid'?'session/new':mode}`);
      expect(retired).toBe(true);
      expect(failed.transport.usable).toBe(false);
      expect(failed.child.exitCode !== null || failed.child.signalCode !== null).toBe(true);
      await expect(failed.transport.request('initialize')).rejects.toThrow('ACP startup failed');
    } finally { failed.child.kill('SIGKILL'); }
    const fresh = await worker('okay');
    try {
      expect(await initializeWorker(fresh.transport, process.cwd(), async () => {
        throw new Error('A successful handshake must not retire its child');
      }, 1000)).toBe('ready');
      expect(fresh.transport.usable).toBe(true);
    } finally { await retireWorker(fresh.child, 50); }
  });
}
