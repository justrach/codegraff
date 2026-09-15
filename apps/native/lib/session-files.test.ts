import { test, expect } from "bun:test";
import { chmodSync, existsSync, mkdirSync, mkdtempSync, readFileSync, readdirSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import os from "node:os";
import path from "node:path";
import { archiveSavedSession, deleteSavedSession } from "./session-files";

function fixture(transcript = true) {
  const root = mkdtempSync(path.join(os.tmpdir(), "session-files-"));
  const file = path.join(root, "saved.session.json"), companion = path.join(root, "saved.transcript.jsonl");
  writeFileSync(file, '{"messages":[]}');
  if (transcript) writeFileSync(companion, '{"content":"older attachment reference"}\n');
  return { root, file, companion, dispose: () => rmSync(root, { recursive: true, force: true }) };
}

test("delete removes checkpoint and full transcript without deleting neighboring files", () => {
  const f = fixture();
  try {
    const other = path.join(f.root, "saved-other.transcript.jsonl");
    writeFileSync(other, "another conversation");
    deleteSavedSession(f.file);
    expect(existsSync(f.file)).toBe(false);
    expect(existsSync(f.companion)).toBe(false);
    expect(readFileSync(other, "utf8")).toBe("another conversation");
  } finally { f.dispose(); }
});

test("archive keeps checkpoint and full transcript together under the same name", () => {
  const f = fixture();
  try {
    const archived = archiveSavedSession(f.file);
    expect(readFileSync(archived, "utf8")).toBe('{"messages":[]}');
    expect(readFileSync(archived.replace(/\.session\.json$/, ".transcript.jsonl"), "utf8")).toContain("older attachment reference");
    expect(existsSync(f.file)).toBe(false);
    expect(existsSync(f.companion)).toBe(false);
  } finally { f.dispose(); }
});

test("an older companion-only archive cannot be overwritten or paired with a different checkpoint", () => {
  const f = fixture();
  try {
    const directory = path.join(f.root, "archived"); mkdirSync(directory);
    const earlier = path.join(directory, "saved.transcript.jsonl"); writeFileSync(earlier, "earlier archive");
    const archived = archiveSavedSession(f.file);
    expect(path.basename(archived)).not.toBe("saved.session.json");
    expect(readFileSync(earlier, "utf8")).toBe("earlier archive");
    expect(readFileSync(archived.replace(/\.session\.json$/, ".transcript.jsonl"), "utf8")).toContain("older attachment reference");
    expect(readdirSync(directory)).toHaveLength(3);
  } finally { f.dispose(); }
});

test("older checkpoints without a transcript can still be archived and deleted", () => {
  const f = fixture(false);
  try {
    const archived = archiveSavedSession(f.file);
    deleteSavedSession(archived);
    expect(existsSync(archived)).toBe(false);
  } finally { f.dispose(); }
});

test("an invalid companion leaves both the indexed session and unrelated content untouched", () => {
  const f = fixture(false);
  try {
    mkdirSync(f.companion); writeFileSync(path.join(f.companion, "keep"), "keep");
    expect(() => deleteSavedSession(f.file)).toThrow("not a regular file");
    expect(() => archiveSavedSession(f.file)).toThrow("not a regular file");
    expect(existsSync(f.file)).toBe(true);
    expect(readFileSync(path.join(f.companion, "keep"), "utf8")).toBe("keep");
  } finally { f.dispose(); }
});

test("a symlinked companion never grants authority to remove a user original", () => {
  const f = fixture(false);
  try {
    const original = path.join(f.root, "original.txt"); writeFileSync(original, "user original");
    symlinkSync(original, f.companion);
    expect(() => deleteSavedSession(f.file)).toThrow("not a regular file");
    expect(() => archiveSavedSession(f.file)).toThrow("not a regular file");
    expect(existsSync(f.file)).toBe(true);
    expect(readFileSync(original, "utf8")).toBe("user original");
  } finally { f.dispose(); }
});

test("both transcript generations follow their checkpoint through archive and deletion", () => {
  const f = fixture();
  try {
    const rotated = path.join(f.root, "saved.transcript.1.jsonl");
    writeFileSync(rotated, '{"content":"oldest image reference"}\n');
    const archived = archiveSavedSession(f.file);
    const archivedRotated = archived.replace(/\.session\.json$/, ".transcript.1.jsonl");
    expect(readFileSync(archivedRotated, "utf8")).toContain("oldest image reference");
    expect(existsSync(rotated)).toBe(false);
    deleteSavedSession(archived);
    expect(existsSync(archivedRotated)).toBe(false);
    expect(existsSync(archived.replace(/\.session\.json$/, ".transcript.jsonl"))).toBe(false);
    expect(existsSync(archived)).toBe(false);
  } finally { f.dispose(); }
});

test("a rotated-only archive reserves the whole stem and cannot be overwritten", () => {
  const f = fixture(false);
  try {
    const directory = path.join(f.root, "archived"); mkdirSync(directory);
    const previous = path.join(directory, "saved.transcript.1.jsonl");
    writeFileSync(previous, "previous archive");
    const archived = archiveSavedSession(f.file);
    expect(path.basename(archived)).not.toBe("saved.session.json");
    expect(readFileSync(previous, "utf8")).toBe("previous archive");
    expect(existsSync(archived.replace(/\.session\.json$/, ".transcript.1.jsonl"))).toBe(false);
  } finally { f.dispose(); }
});


test.skipIf(process.platform === "win32" || process.getuid?.() === 0)("an unwritable archive preserves the checkpoint and its transcript", () => {
  const f = fixture(), archive = path.join(f.root, "archived");
  mkdirSync(archive); chmodSync(archive, 0o500);
  try {
    expect(() => archiveSavedSession(f.file)).toThrow();
    expect(readFileSync(f.file, "utf8")).toBe('{"messages":[]}');
    expect(readFileSync(f.companion, "utf8")).toContain("older attachment reference");
    expect(readdirSync(archive)).toHaveLength(0);
  } finally { chmodSync(archive, 0o700); f.dispose(); }
});
