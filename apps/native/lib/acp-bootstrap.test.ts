import { test, expect } from "bun:test";
import { spawn } from "node:child_process";
import { once } from "node:events";
import { AcpTransport } from "./acp-transport";
import { initializeWorker, serializeBootstrap } from "./acp-bootstrap";
import { retireWorker } from "./acp-retire";

async function worker(mode: string) {
  const child = spawn(process.execPath, ["-e", `
    const mode = ${JSON.stringify(mode)};
    const send = value => console.log(JSON.stringify(value));
    require('node:readline').createInterface({input:process.stdin}).on('line', line => {
      const req=JSON.parse(line);
      if(req.method==='initialize' && mode!=='initialize') send({id:req.id,result:{}});
      if(req.method==='session/new' && mode!=='session/new') send({id:req.id,result:mode==='invalid'?{}:mode==='isolated'?{sessionId:'ready',cwd:'/isolated/tree'}:{sessionId:'ready'}});
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
      }, 1000)).toEqual({ sessionId: 'ready' });
      expect(fresh.transport.usable).toBe(true);
    } finally { await retireWorker(fresh.child, 50); }
  });
}


test("session/new checkout binds the worker to its isolated worktree", async () => {
  const isolated = await worker("isolated");
  try {
    expect(await initializeWorker(isolated.transport, "/shared/repo", async () => {
      throw new Error("A successful handshake must not retire its child");
    }, 1000)).toEqual({ sessionId: "ready", cwd: "/isolated/tree" });
  } finally { await retireWorker(isolated.child, 50); }
});

test("overlapping startup and first prompt share a completed worker", async () => {
  const pending = new Map<string, Promise<string>>();
  let live: Awaited<ReturnType<typeof worker>> | undefined;
  let session: string | undefined;
  let starts = 0;
  const start = async () => {
    if (session) return session;
    starts++;
    live = await worker("okay");
    session = (await initializeWorker(live.transport, process.cwd(), async () => {
      await retireWorker(live!.child, 50);
    }, 1000)).sessionId;
    return session;
  };
  try {
    expect(await Promise.all([
      serializeBootstrap(pending, "chat", start),
      serializeBootstrap(pending, "chat", start),
      serializeBootstrap(pending, "chat", start),
    ])).toEqual(["ready", "ready", "ready"]);
    expect(starts).toBe(1);
    expect(live?.transport.usable).toBe(true);
    expect(pending.size).toBe(0);
  } finally { if (live) await retireWorker(live.child, 50); }
});

test("a failed startup rejects queued callers without resurrecting it", async () => {
  const pending = new Map<string, Promise<string>>();
  let fail!: (error: Error) => void;
  let queuedStarts = 0;
  const first = serializeBootstrap(pending, "chat", () => new Promise<string>((_, reject) => { fail = reject; }));
  const second = serializeBootstrap(pending, "chat", async () => { queuedStarts++; return "unexpected"; });
  const results = Promise.allSettled([first, second]);
  await Promise.resolve();
  fail(new Error("startup disposed"));
  expect((await results).map(result => result.status)).toEqual(["rejected", "rejected"]);
  expect(queuedStarts).toBe(0);
  expect(pending.size).toBe(0);
  expect(await serializeBootstrap(pending, "chat", async () => "retry")).toBe("retry");
});

test("queued option changes wait while other chats stay independent", async () => {
  const pending = new Map<string, Promise<string>>();
  let ready!: (value: string) => void;
  let current = "first workspace";
  const first = serializeBootstrap(pending, "chat", () => new Promise<string>(resolve => { ready = resolve; }));
  const moved = serializeBootstrap(pending, "chat", async () => { current = "second workspace"; return current; });
  expect(await serializeBootstrap(pending, "other", async () => "independent")).toBe("independent");
  expect(current).toBe("first workspace");
  ready(current);
  expect(await first).toBe("first workspace");
  expect(await moved).toBe("second workspace");
  expect(pending.size).toBe(0);
});
