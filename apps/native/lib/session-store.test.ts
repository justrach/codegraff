import { describe, it } from "node:test";
import assert from "node:assert/strict";
import { mkdirSync, mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import {
  decodeCursor,
  displayWorkspace,
  encodeCursor,
  filterRows,
  findSessionFile,
  listSessionRows,
  pageSessions,
  sameWorkspace,
  SESSIONS_DIR,
} from "./session-store.ts";

function writeSession(root: string, name: string, body: Record<string, unknown>): void {
  const dir = path.join(root, SESSIONS_DIR);
  mkdirSync(dir, { recursive: true });
  writeFileSync(path.join(dir, `${name}.session.json`), `${JSON.stringify({ ...body, messages: [] })}\n`);
}

describe("displayWorkspace / sameWorkspace", () => {
  it("tilts home and treats a trailing slash as the same tree", () => {
    assert.equal(displayWorkspace("/Users/me", "/Users/me"), "~");
    assert.equal(displayWorkspace("/Users/me/proj", "/Users/me"), "~/proj");
    assert.equal(displayWorkspace("/tmp/other", "/Users/me"), "/tmp/other");
    assert.equal(sameWorkspace("/Users/me", "/Users/me/"), true);
    assert.equal(sameWorkspace("/Users/me", "/tmp/proj"), false);
  });
});

describe("listSessionRows", () => {
  it("lists cwd, then home, and cwd wins on the same name", () => {
    const cwd = mkdtempSync(path.join(tmpdir(), "graff-cwd-"));
    const home = mkdtempSync(path.join(tmpdir(), "graff-home-"));
    writeSession(cwd, "here", { title: "Repo chat", updated_ms: 30, model: "glm-5" });
    writeSession(cwd, "shared", { title: "Cwd copy", updated_ms: 20, model: "glm-5" });
    writeSession(home, "shared", { title: "Home copy", updated_ms: 90, model: "kimi" });
    writeSession(home, "notes", { title: "Kitchen notes", updated_ms: 10, model: "kimi", workspace: home });
    const rows = listSessionRows(cwd, home);
    assert.deepEqual(
      rows.map((r) => r.name),
      ["here", "shared", "notes"],
    );
    const shared = rows.find((r) => r.name === "shared");
    assert.equal(shared?.title, "Cwd copy");
    assert.equal(shared?.local, true);
    const notes = rows.find((r) => r.name === "notes");
    assert.equal(notes?.local, false);
    assert.equal(notes?.origin, "~");
  });
});

describe("pageSessions", () => {
  it("pages newest-first and resumes after the cursor", () => {
    const rows = [40, 30, 20, 10].map((ms, i) => ({
      name: `s${i}`,
      title: `Chat ${i}`,
      updatedMs: ms,
      model: "glm-5",
      provider: null,
      size: 12,
      workspace: "/tmp",
      origin: null,
      local: true,
    }));
    const first = pageSessions(rows, { limit: 2 });
    assert.equal(first.total, 4);
    assert.deepEqual(
      first.sessions.map((s) => s.name),
      ["s0", "s1"],
    );
    assert.equal(first.nextCursor, encodeCursor(30, "s1"));
    const second = pageSessions(rows, { limit: 2, cursor: first.nextCursor });
    assert.deepEqual(
      second.sessions.map((s) => s.name),
      ["s2", "s3"],
    );
    assert.equal(second.nextCursor, null);
  });

  it("filters by query and scope before paging", () => {
    const rows = [
      { name: "a", title: "Fix login", updatedMs: 3, model: "glm-5", provider: null, size: 1, workspace: "/repo", origin: null, local: true },
      { name: "b", title: "Home notes", updatedMs: 2, model: "kimi", provider: null, size: 1, workspace: "/Users/me", origin: "~", local: false },
      { name: "c", title: "Fix tests", updatedMs: 1, model: "glm-5", provider: null, size: 1, workspace: "/repo", origin: null, local: true },
    ];
    const login = filterRows(rows, "login");
    assert.deepEqual(
      login.map((r) => r.name),
      ["a"],
    );
    const elsewhere = pageSessions(rows, { scope: "elsewhere", limit: 10 });
    assert.equal(elsewhere.total, 1);
    assert.equal(elsewhere.sessions[0]?.name, "b");
  });
});

describe("cursors", () => {
  it("round-trips and rejects junk", () => {
    assert.deepEqual(decodeCursor(encodeCursor(99, "native-abc")), { updatedMs: 99, name: "native-abc" });
    assert.equal(decodeCursor("nope"), null);
    assert.equal(decodeCursor("12:"), null);
  });
});

describe("findSessionFile", () => {
  it("prefers cwd and falls back to home", () => {
    const cwd = mkdtempSync(path.join(tmpdir(), "graff-find-cwd-"));
    const home = mkdtempSync(path.join(tmpdir(), "graff-find-home-"));
    writeSession(cwd, "here", { title: "Here", updated_ms: 1 });
    writeSession(home, "away", { title: "Away", updated_ms: 2 });
    assert.equal(findSessionFile(cwd, "here", home)?.local, true);
    assert.equal(findSessionFile(cwd, "away", home)?.local, false);
    assert.equal(findSessionFile(cwd, "missing", home), null);
  });
});
