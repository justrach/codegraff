import { afterEach, expect, test } from "bun:test";
import { mkdtempSync, rmSync, existsSync, utimesSync, writeFileSync, renameSync, chmodSync, readdirSync } from "node:fs";
import os from "node:os";
import path from "node:path";
import { AttachmentStore } from "./attachment-store";
const fixtures: { store: AttachmentStore; root: string }[] = [];
function fixture(owner = 12345, alive = (_pid: number) => true) {
  const root = mkdtempSync(path.join(os.tmpdir(), "graff-attachment-lifetime-"));
  const store = new AttachmentStore(root, owner, alive);
  fixtures.push({ store, root }); return { store, root };
}
afterEach(() => { for (const {store, root} of fixtures.splice(0)) { store.close(); rmSync(root, { recursive: true, force: true }); } });
test("aged drafts survive uploads and sweep while their desktop owner is alive", () => {
  const {store} = fixture();
  const draft = store.create("draft.png", new Uint8Array([1, 2, 3]));
  const old = new Date(Date.now() - 48 * 60 * 60 * 1000); utimesSync(draft, old, old);
  store.create("next.png", new Uint8Array([4]));
  expect(store.sweep()).toBe(0); expect(existsSync(draft)).toBe(true);
  expect(store.discard(draft)).toBe(true); expect(existsSync(draft)).toBe(false);
});
test("accepted prompt attachments survive producer exit and a new store instance", () => {
  const {store, root} = fixture(12345, () => false);
  const sent = store.create("sent.png", new Uint8Array([1]));
  store.retainPrompt({ prompt: [{ type: "text", text: `Inspect @[${sent}]` }] });
  store.close();
  const restarted = new AttachmentStore(root, 67890, () => false);
  try { expect(restarted.sweep()).toBe(0); expect(restarted.discard(sent)).toBe(false); expect(existsSync(sent)).toBe(true); }
  finally { restarted.close(); }
});
test("recovery is bounded and removes only abandoned recorded pending uploads", () => {
  const {store, root} = fixture(12345, () => false);
  const files = Array.from({length: 5}, () => store.create("pending.png", new Uint8Array([1])));
  writeFileSync(path.join(root, "original.png"), "original");
  expect(store.sweep(2)).toBe(2); expect(files.filter(existsSync)).toHaveLength(3);
  expect(store.sweep(2)).toBe(2); expect(files.filter(existsSync)).toHaveLength(1);
  expect(store.sweep(2)).toBe(1); expect(files.filter(existsSync)).toHaveLength(0);
  expect(existsSync(path.join(root, "original.png"))).toBe(true);
});
test("unknown ownership and replacement files are never recovery deletion authority", () => {
  const unknown = fixture(0, () => false);
  const pending = unknown.store.create("pending.png", new Uint8Array([1]));
  expect(unknown.store.sweep()).toBe(0); expect(existsSync(pending)).toBe(true);
  const {store, root} = fixture(12345, () => false);
  const replaced = store.create("pending.png", new Uint8Array([2]));
  const original = path.join(root, "original.png"); writeFileSync(original, "original"); renameSync(original, replaced);
  expect(store.discard(replaced)).toBe(false); expect(store.sweep()).toBe(0); expect(existsSync(replaced)).toBe(true);
  expect(store.discard(path.join(root, "..", "unrelated.png"))).toBe(false);
});


test("a failed ownership-record write removes its newly created upload", () => {
  if (process.platform === "win32" || process.getuid?.() === 0) return;
  const {store, root} = fixture();
  const existing = store.create("existing.png", new Uint8Array([1]));
  const records = path.join(root, ".ownership");
  chmodSync(records, 0o500);
  try {
    expect(() => store.create("failed.png", new Uint8Array([2]))).toThrow();
    expect(readdirSync(root).filter(name => name.endsWith("-failed.png"))).toEqual([]);
    expect(existsSync(existing)).toBe(true);
  } finally { chmodSync(records, 0o700); }
});
