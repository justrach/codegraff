import { test } from "bun:test";
import assert from "node:assert/strict";
import { parseCreate, runCommand, sanitizeSlug, slugFromCheckout } from "./worktree-cli";

test("sanitizeSlug matches the engine's workspace names", () => {
  assert.equal(sanitizeSlug("tokyo"), "tokyo");
  assert.equal(sanitizeSlug(" task-a "), "task-a");
  assert.equal(sanitizeSlug("a/b"), null);
  assert.equal(sanitizeSlug(".."), null);
  assert.equal(sanitizeSlug(""), null);
});

test("parseCreate reads graff worktree create output", () => {
  const got = parseCreate(
    "✓ workspace tokyo\n  path /repo/.graff/worktrees/tokyo\n  branch worktree-tokyo\n  copied 2 gitignored file(s)\n  setup ok\n",
  );
  assert.deepEqual(got, {
    name: "tokyo",
    path: "/repo/.graff/worktrees/tokyo",
    branch: "worktree-tokyo",
    copied: 2,
  });
});

test("slugFromCheckout reads a task worktree folder", () => {
  assert.equal(slugFromCheckout("/repo/.graff/worktrees/tokyo"), "tokyo");
  assert.equal(slugFromCheckout("/repo"), null);
  assert.equal(runCommand("tokyo"), "graff worktree run tokyo");
});
