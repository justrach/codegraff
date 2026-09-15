import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, mkdirSync, writeFileSync, rmSync, realpathSync, symlinkSync } from "node:fs";
import os from "node:os";
import path from "node:path";
import { createHash } from "node:crypto";
import { discoverWorkspaceHistory } from "./workspace-history";
import { mergeWorkspaceActivity, savedWorkspaceChoices, compareWorkspaceActivity } from "./workspaces";

test("history requires real saves, preserves exact roots, ranks activity and tolerates missing hints", () => {
  const home = realpathSync(mkdtempSync(path.join(os.tmpdir(), "workspace-history-")));
  try {
    const register = (root: string) => {
      mkdirSync(root, { recursive: true });
      const dir = path.join(home, ".graff/workspace-history"); mkdirSync(dir, { recursive: true });
      writeFileSync(path.join(dir, createHash("sha256").update(root).digest("hex") + ".json"), JSON.stringify({ version: 1, path: root }));
    };
    const save = (root: string, updated: number, archive = false) => {
      const dir = path.join(root, ".graff/sessions", archive ? "archived" : ""); mkdirSync(dir, { recursive: true });
      writeFileSync(path.join(dir, "one.session.json"), JSON.stringify({ updated_ms: updated, messages: [{ role: "user", content: "Hello" }] }));
    };
    const older = path.join(home, "repo/nested"), newer = path.join(home, "newer"), unused = path.join(home, "unused");
    register(older); register(newer); register(unused); save(older, 100); save(newer, 200, true);
    writeFileSync(path.join(home, ".graff/workspace-history", "f".repeat(64) + ".json"), "bad json");
    const alias = path.join(home, "alias"); symlinkSync(older, alias);
    assert.deepEqual(discoverWorkspaceHistory([alias], home), [{ path: newer, lastActivityMs: 200 }, { path: alias, lastActivityMs: 100 }]);
    rmSync(newer, { recursive: true });
    assert.deepEqual(discoverWorkspaceHistory([], home), [{ path: older, lastActivityMs: 100 }]);
    const oldKnown = path.join(home, "unregistered"); save(oldKnown, 300);
    assert.equal(discoverWorkspaceHistory([oldKnown], home)[0].path, oldKnown);
  } finally { rmSync(home, { recursive: true, force: true }); }
});

test("suggestions retain saved settings without consuming choices and sort by activity", () => {
  const saved = Array.from({ length: 50 }, (_, i) => ({ path: `/saved/${i}`, name: `Custom ${i}`, yolo: false }));
  const activity = [{ path: "/terminal-only", lastActivityMs: 300 }, { path: "/saved/0", lastActivityMs: 200 }];
  const result = mergeWorkspaceActivity(saved, activity);
  assert.equal(result.length, 51); assert.equal(savedWorkspaceChoices(result).length, 50);
  assert.equal(savedWorkspaceChoices(result)[0].lastActivityMs, undefined);
  assert.equal(result[0].name, "Custom 0"); assert.equal(result[0].yolo, false);
  assert.equal(result.toSorted(compareWorkspaceActivity)[0].path, "/terminal-only");
  assert.equal(result.find(row => row.path === "/terminal-only")?.source, "history");
  assert.equal(mergeWorkspaceActivity(result, activity).length, 51);
  assert.equal(mergeWorkspaceActivity([{ path: "/terminal-only", name: "terminal", source: "startup" }], activity)[0].source, "history");
});
