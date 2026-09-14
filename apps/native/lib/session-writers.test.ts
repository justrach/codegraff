import { test, expect } from "bun:test";
import { spawn } from "node:child_process";
import { once } from "node:events";
import { mkdtempSync, mkdirSync, readFileSync, writeFileSync, unlinkSync, existsSync, renameSync, rmSync } from "node:fs";
import os from "node:os";
import path from "node:path";
import { assertSessionWritable, closeSessionWriter, registerSessionWriter, sessionFile, withSessionWritersStopped } from "./session-writers";

async function fixture() {
  const root = mkdtempSync(path.join(os.tmpdir(), "session-writers-"));
  const file = sessionFile(root, "saved");
  mkdirSync(path.dirname(file), { recursive: true });
  writeFileSync(file, "initial");
  const child = spawn(process.execPath, ["-e", `
    const fs = require('node:fs');
    process.stdin.resume();
    process.stdin.on('end', () => setTimeout(() => {
      fs.writeFileSync(process.argv[1], 'final save'); process.exit(0);
    }, 100));
    console.log('ready');
  `, file], { stdio: ["pipe", "pipe", "inherit"] });
  await once(child.stdout!, "data");
  return { root, file, child, async dispose() {
    if (child.exitCode === null && child.signalCode === null) {
      const exited = once(child, "exit"); child.kill("SIGKILL"); await exited;
    }
    rmSync(root, { recursive: true, force: true });
  } };
}

test("deletion waits for a closing tab's final save instead of resurrecting its session", async () => {
  const f = await fixture();
  try {
    let detached = false;
    registerSessionWriter(f.file, f.child, () => { detached = true; });
    const closing = closeSessionWriter(f.child);
    await withSessionWritersStopped(f.file, () => {
      expect(f.child.exitCode).toBe(0);
      expect(readFileSync(f.file, "utf8")).toBe("final save");
      unlinkSync(f.file);
    });
    await closing;
    expect(detached).toBe(true);
    expect(existsSync(f.file)).toBe(false);
  } finally { await f.dispose(); }
});

test("archive includes the final save and prevents new writers until mutation completes", async () => {
  const f = await fixture();
  try {
    registerSessionWriter(f.file, f.child, () => {});
    const archive = path.join(f.root, "archived.session.json");
    await withSessionWritersStopped(f.file, async () => {
      expect(() => assertSessionWritable(f.file)).toThrow("being removed");
      await expect(withSessionWritersStopped(f.file, () => {})).rejects.toThrow("being removed");
      renameSync(f.file, archive);
      await Promise.resolve();
      expect(() => assertSessionWritable(f.file)).toThrow("being removed");
    });
    expect(() => assertSessionWritable(f.file)).not.toThrow();
    expect(readFileSync(archive, "utf8")).toBe("final save");
    expect(existsSync(f.file)).toBe(false);
  } finally { await f.dispose(); }
});

test("deleting one saved session retires all its writers and leaves unrelated sessions running", async () => {
  const first = await fixture(), second = await fixture(), unrelated = await fixture();
  try {
    registerSessionWriter(first.file, first.child, () => {});
    registerSessionWriter(first.file, second.child, () => {});
    registerSessionWriter(unrelated.file, unrelated.child, () => {});
    await withSessionWritersStopped(first.file, () => unlinkSync(first.file));
    expect(first.child.exitCode).toBe(0);
    expect(second.child.exitCode).toBe(0);
    expect(unrelated.child.exitCode).toBeNull();
    expect(readFileSync(unrelated.file, "utf8")).toBe("initial");
  } finally { await first.dispose(); await second.dispose(); await unrelated.dispose(); }
});

test("a failed mutation releases the gate without claiming file removal", async () => {
  const f = await fixture();
  try {
    registerSessionWriter(f.file, f.child, () => {});
    await expect(withSessionWritersStopped(f.file, () => { throw new Error("write denied"); })).rejects.toThrow("write denied");
    expect(existsSync(f.file)).toBe(true);
    expect(() => assertSessionWritable(f.file)).not.toThrow();
  } finally { await f.dispose(); }
});
