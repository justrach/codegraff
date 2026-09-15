import { expect, test } from "bun:test";
import { spawn } from "node:child_process";
import { once } from "node:events";
import { mkdtempSync, mkdirSync, rmSync, writeFileSync } from "node:fs";
import os from "node:os";
import path from "node:path";
import { AttachmentStore } from "./attachment-store";
import { attachmentConsumers, enrollAttachmentConsumer } from "./attachment-consumers";

test("worker consumers survive store restart and release only after both processes exit", async () => {
  const root = mkdtempSync(path.join(os.tmpdir(), "graff-live-image-consumers-"));
  const workers = [spawn(process.execPath, ["-e", "setInterval(() => {}, 1000)"]),
    spawn(process.execPath, ["-e", "setInterval(() => {}, 1000)"])];
  const exits = workers.map(child => once(child, "exit"));
  const alive = (pid: number) => {
    if (pid === 2147483647) return false; // The producer has already exited.
    try { process.kill(pid, 0); return true; }
    catch (error) { return (error as NodeJS.ErrnoException).code !== "ESRCH"; }
  };
  const original = new AttachmentStore(root, 2147483647, alive);
  const restarted = new AttachmentStore(root, 2147483647, alive);
  try {
    await Promise.all(workers.map(child => once(child, "spawn")));
    const sessions = path.join(root, "sessions"); mkdirSync(sessions);
    const image = original.create("shared.png", new Uint8Array([1]));
    const prompt = { prompt: [{ type: "text", text: `@[${image}]` }] };
    for (const child of workers) original.retainPrompt(prompt, sessions, child.pid);
    original.close();
    // No checkpoint exists yet: absence must not conceal the in-memory worker.
    expect(restarted.references(image)).toBe("absent");
    expect(restarted.consumers(image)).toBe("active");
    workers[0].kill(); await exits[0];
    expect(restarted.consumers(image)).toBe("active");
    workers[1].kill(); await exits[1];
    expect(restarted.consumers(image)).toBe("inactive");
    expect(restarted.discard(image)).toBe(false); // Cross-surface collection is not enabled yet.
  } finally {
    for (const child of workers) if (child.exitCode === null && child.signalCode === null) child.kill();
    await Promise.all(exits);
    original.close(); restarted.close(); rmSync(root, { recursive: true, force: true });
  }
});

test("unknown, malformed and unenrolled consumers never prove inactivity", () => {
  const root = mkdtempSync(path.join(os.tmpdir(), "graff-unknown-image-consumers-"));
  try {
    expect(attachmentConsumers(root, 12345, () => false)).toBe("unknown");
    enrollAttachmentConsumer(root, 54321);
    expect(attachmentConsumers(root, 12345, () => false)).toBe("inactive");
    expect(attachmentConsumers(root, 12345, pid => pid === 12345)).toBe("active");
    expect(attachmentConsumers(root, 0, () => false)).toBe("unknown");
    writeFileSync(path.join(root, "broken.json"), "{");
    expect(attachmentConsumers(root, 12345, () => false)).toBe("unknown");
    rmSync(path.join(root, "broken.json"));
    enrollAttachmentConsumer(root);
    enrollAttachmentConsumer(root, 54321);
    expect(attachmentConsumers(root, 12345, () => false)).toBe("unknown");
  } finally { rmSync(root, { recursive: true, force: true }); }
});

test("a resumed workspace worker protects old images without a new image prompt", async () => {
  const root=mkdtempSync(path.join(os.tmpdir(),"graff-resumed-image-consumers-"));
  const child=spawn(process.execPath,["-e","setInterval(() => {}, 1000)"]);
  const exited=once(child,"exit");
  const alive=(pid:number)=>{
    if(pid===2147483647)return false;
    try{process.kill(pid,0);return true;}catch(error){return (error as NodeJS.ErrnoException).code!=="ESRCH";}
  };
  const store=new AttachmentStore(root,2147483647,alive);
  try {
    await once(child,"spawn");
    const scope=path.join(root,"sessions");mkdirSync(scope);
    const image=store.create("old.png",new Uint8Array([1]));
    store.retainPrompt({prompt:[{type:"text",text:`@[${image}]`}]},scope,2147483647);
    expect(store.consumers(image)).toBe("inactive");
    store.enrollSession(scope,child.pid); // Resume loads history, not a new pasted-image turn.
    const restarted=new AttachmentStore(root,2147483647,alive);
    try {
      expect(restarted.references(image)).toBe("absent");
      expect(restarted.consumers(image)).toBe("active");
      child.kill();await exited;
      expect(restarted.consumers(image)).toBe("inactive");
    } finally {restarted.close();}
  } finally {
    if(child.exitCode===null && child.signalCode===null)child.kill();
    await exited;store.close();rmSync(root,{recursive:true,force:true});
  }
});
