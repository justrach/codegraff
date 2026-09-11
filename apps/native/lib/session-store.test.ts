import { describe, it } from "node:test";
import assert from "node:assert/strict";
import { mkdirSync, mkdtempSync, readFileSync, rmSync, statSync, writeFileSync } from "node:fs";
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
  recoveredSessionTitle,
  MAX_FULL_BYTES,
  SESSIONS_DIR,
} from "./session-store.ts";

function writeSession(root: string, name: string, body: Record<string, unknown>): void {
  const dir = path.join(root, SESSIONS_DIR);
  mkdirSync(dir, { recursive: true });
  writeFileSync(path.join(dir, `${name}.session.json`), `${JSON.stringify({ ...body, messages: body.messages ?? [] })}\n`);
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

describe("legacy placeholder titles", () => {
  it("recovers Responses input_text from a real image-bearing file and preserves named titles", () => {
    const cwd = mkdtempSync(path.join(tmpdir(), "graff-legacy-"));
    const messages = [
      { role: "user", content: "  [peer] wake" },
      { role: "user", content: [{ type: "input_text", text: "[presence] online" }] },
      { role: "user", content: " \n " },
      { role: "assistant", content: "Not the title" },
      { role: "user", content: [
        { type: "input_text", text: "Fix the screenshot layout\n<graff-gui-skill-context>\nHidden instructions\n</graff-gui-skill-context>" },
        { type: "input_image", image_url: `data:image/png;base64,${"A".repeat(100_000)}` },
      ] },
    ];
    writeSession(cwd, "legacy", { title: "Untitled session", messages });
    writeSession(cwd, "named", { title: "My chosen title", messages });
    const rows = listSessionRows(cwd, cwd);
    assert.equal(rows.find(row => row.name === "legacy")?.title, "Fix the screenshot layout");
    assert.equal(rows.find(row => row.name === "named")?.title, "My chosen title");
    // The GET metadata path uses this same recovery on the parsed messages.
    assert.equal(recoveredSessionTitle("Untitled session", messages), "Fix the screenshot layout");
    writeSession(cwd, "legacy", { title: "Untitled session", updated_ms: 2, messages: [...messages, { role: "assistant", content: "Appended reply" }] });
    assert.equal(listSessionRows(cwd, cwd).find(row => row.name === "legacy")?.title, "Fix the screenshot layout");
  });

  it("supports string/text content, empty and injected turns, and UTF-8 boundaries", () => {
    for (const content of ["  Real prompt  ", [{ type: "text", text: "  Real prompt  " }]]) {
      assert.equal(recoveredSessionTitle("Untitled session", [{ role: "user", content }]), "Real prompt");
    }
    assert.equal(recoveredSessionTitle("Named", [{ role: "user", content: "Other" }]), "Named");
    assert.equal(recoveredSessionTitle("Untitled session", [{ role: "user", content: "[#469 channel] wake" }]), "Untitled session");
    assert.equal(recoveredSessionTitle("Untitled session", [{ role: "user", content: "😀".repeat(30) }]), "😀".repeat(20));
  });

  it("keeps the placeholder when a legacy file exceeds the full-read limit", () => {
    const cwd = mkdtempSync(path.join(tmpdir(), "graff-large-"));
    writeSession(cwd, "large", { title: "Untitled session", messages: [{ role: "user", content: "Prompt" }, { role: "assistant", content: "x".repeat(MAX_FULL_BYTES) }] });
    assert.equal(listSessionRows(cwd, cwd)[0]?.title, "Untitled session");
  });
});

describe("GUI legacy recovery regressions", () => {
  function fixture(t: { after: (fn: () => void) => void }): string {
    const root = mkdtempSync(path.join(tmpdir(), "graff-recovery-test-"));
    t.after(() => rmSync(root, { recursive: true, force: true }));
    return root;
  }

  function assertReadParity(root: string, name: string, expected: string): void {
    const file = findSessionFile(root, name, root)?.file;
    assert.ok(file);
    const body = JSON.parse(readFileSync(file, "utf8"));
    const row = listSessionRows(root, root).find(row => row.name === name);
    assert.ok(row);
    assert.equal(recoveredSessionTitle(body.title, body.messages), expected, "read metadata title");
    assert.equal(row.title, expected, "list metadata title");
    assert.equal(row.updatedMs, body.updated_ms);
    assert.equal(row.model, body.model);
    assert.equal(row.provider, body.provider);
    assert.equal(row.workspace, body.workspace);
    assert.equal(row.size, statSync(file).size);
  }

  it("keeps valid header metadata when the message JSON is malformed or partially saved", t => {
    const root = fixture(t);
    const header = { title: "Untitled session", updated_ms: 71, model: "test-model", provider: "test-provider", workspace: root };
    for (const [name, tail] of [["partial", '[{"role":"user","content":"unfinished'], ["malformed", '[invalid]}']] as const) {
      writeSession(root, name, header);
      writeFileSync(path.join(root, SESSIONS_DIR, `${name}.session.json`), `${JSON.stringify(header).slice(0, -1)},"messages":${tail}`);
      const row = listSessionRows(root, root).find(row => row.name === name);
      assert.ok(row);
      assert.equal(row.title, header.title);
      assert.equal(row.updatedMs, header.updated_ms);
      assert.equal(row.model, header.model);
      assert.equal(row.provider, header.provider);
      assert.equal(row.workspace, root);
    }
  });

  it("skips empty, image-only, blank, malformed, and non-user message parts", () => {
    const skipped = [null, 7, {}, { role: "assistant", content: "Not human" },
      ...[null, {}, [], " \n\t ", [{ type: "input_image", image_url: "data:image/png;base64,AA==" }],
        [null, 8, {}, { type: "text", text: 123 }, { type: "input_text", text: null }, { type: "unknown", text: "Not text" }],
        [{ type: "text", text: " " }, { type: "input_text", text: "\n" }],
      ].map(content => ({ role: "user", content }))];
    assert.equal(recoveredSessionTitle("Untitled session", skipped), "Untitled session");
    assert.equal(recoveredSessionTitle("Untitled session", [...skipped,
      { role: "user", content: [null, { type: "input_text", text: "First human prompt" }, { type: "text", text: false }] },
    ]), "First human prompt");
  });

  for (const prefix of ["[peer]", "[peer message", "[presence]", "[#469 presence]", "[#469 channel", "[#469 device room", "[peer channel"]) {
    it(`skips injected ${prefix} turns in every text representation`, () => {
      for (const content of [` \n${prefix} synthetic notice`, [{ type: "text", text: `${prefix} synthetic notice` }], [{ type: "input_text", text: `${prefix} synthetic notice` }]]) {
        assert.equal(recoveredSessionTitle("Untitled session", [
          { role: "user", content }, { role: "user", content: "Human question" },
        ]), "Human question");
      }
    });
  }

  it("matches string, text, and input_text at mixed Unicode byte boundaries", () => {
    for (const [prompt, expected] of [
      ["a".repeat(77) + "😀end", "a".repeat(77)],
      ["a".repeat(76) + "😀end", "a".repeat(76) + "😀"],
      ["界".repeat(27), "界".repeat(26)],
      ["é".repeat(40) + "x", "é".repeat(40)],
    ]) {
      for (const content of [prompt, [{ type: "text", text: prompt }], [{ type: "input_text", text: prompt }]]) {
        assert.equal(recoveredSessionTitle("Untitled session", [{ role: "user", content }]), expected);
      }
    }
  });

  it("finds the first human title beyond the 64 KiB header peek", t => {
    const root = fixture(t);
    writeSession(root, "late", { title: "Untitled session", updated_ms: 81, model: "test-model", provider: "test-provider", workspace: root,
      messages: [{ role: "user", content: [{ type: "input_image", image_url: "A".repeat(70_000) }] },
        { role: "user", content: [{ type: "input_text", text: "Late human prompt" }] }] });
    assertReadParity(root, "late", "Late human prompt");
  });

  for (const padding of [0, 70_000]) {
    it(`invalidates a cached title when the first human prompt changes after ${padding} padding bytes`, t => {
      const root = fixture(t);
      const save = (prompt: string, updated_ms: number) => writeSession(root, "rewrite", {
        title: "Untitled session", updated_ms, model: "test-model", provider: "test-provider", workspace: root,
        messages: [{ role: "assistant", content: "x".repeat(padding) }, { role: "user", content: prompt }],
      });
      save("Original human prompt", 91);
      assertReadParity(root, "rewrite", "Original human prompt");
      const file = path.join(root, SESSIONS_DIR, "rewrite.session.json");
      const before = readFileSync(file).subarray(0, 64 * 1024);
      // Equal-length text and unchanged header deliberately isolate prefix-only caching.
      save("Replaced human prompt", 91);
      if (padding) assert.deepEqual(readFileSync(file).subarray(0, 64 * 1024), before);
      assertReadParity(root, "rewrite", "Replaced human prompt");
    });
  }

  it("refreshes metadata and honors a rename after caching placeholder recovery", t => {
    const root = fixture(t);
    const messages = [{ role: "user", content: "Recovered original" }];
    writeSession(root, "rename", { title: "Untitled session", updated_ms: 101, model: "model-one", provider: "provider-one", workspace: root, messages });
    assertReadParity(root, "rename", "Recovered original");
    writeSession(root, "rename", { title: "Untitled session", updated_ms: 102, model: "model-two", provider: "provider-two", workspace: `${root}/nested`, messages });
    assertReadParity(root, "rename", "Recovered original");
    writeSession(root, "rename", { title: "Explicitly renamed", updated_ms: 103, model: "model-three", provider: "provider-three", workspace: root, messages });
    assertReadParity(root, "rename", "Explicitly renamed");
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
