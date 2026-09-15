import { afterEach, expect, test } from "bun:test";
import { mkdtempSync, rmSync, existsSync, utimesSync, writeFileSync, renameSync, chmodSync, readdirSync, mkdirSync } from "node:fs";
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

test("an in-place edit is preserved even when the inode and byte count match", () => {
  const {store} = fixture(12345, () => false);
  const edited = store.create("edited.png", new Uint8Array([1,2,3]));
  writeFileSync(edited, new Uint8Array([4,5,6]));
  expect(store.discard(edited)).toBe(false);
  expect(store.sweep()).toBe(0);
  expect(existsSync(edited)).toBe(true);
});

test("enrolled workspace references survive restart and independent archive deletion", () => {
  const {store,root} = fixture();
  const first = path.join(root,"first"), second = path.join(root,"second");
  mkdirSync(first);mkdirSync(second);
  const sent = store.create("shared.png",new Uint8Array([1]));
  const prompt = {prompt:[{type:"text",text:`Inspect @[${sent}]`}]};
  store.retainPrompt(prompt,first);store.retainPrompt(prompt,second);
  const a=path.join(first,"chat.session.json"), b=path.join(second,"chat.session.json");
  writeFileSync(a,JSON.stringify({messages:[sent]}));writeFileSync(b,JSON.stringify({messages:[sent]}));
  const restarted=new AttachmentStore(root,67890,()=>false);
  try {
    expect(restarted.references(sent)).toBe("referenced");rmSync(a);
    const archive=path.join(second,"archived");mkdirSync(archive);
    renameSync(b,path.join(archive,"chat.session.json"));
    expect(restarted.references(sent)).toBe("referenced");
    rmSync(path.join(archive,"chat.session.json"));
    expect(restarted.references(sent)).toBe("absent");
    expect(existsSync(sent)).toBe(true); // Absence evidence alone is not deletion authority.
  } finally { restarted.close(); }
});

test("an unscoped submission cannot be retroactively treated as complete scope knowledge", () => {
  const {store,root}=fixture();const scope=path.join(root,"sessions");mkdirSync(scope);
  const sent=store.create("unknown.png",new Uint8Array([1]));
  const prompt={prompt:[{type:"text",text:`@[${sent}]`}]};
  store.retainPrompt(prompt);store.retainPrompt(prompt,scope);
  expect(store.references(sent)).toBe("unknown");
});
