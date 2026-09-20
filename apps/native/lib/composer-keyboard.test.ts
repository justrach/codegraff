import { test } from "node:test";
import assert from "node:assert/strict";
import { shouldPickComposerRow } from "./composer-keyboard.ts";

test("an open composer menu does not capture Enter or Tab before a row is visibly selected", () => {
  assert.equal(shouldPickComposerRow("Enter", false, false), false);
  assert.equal(shouldPickComposerRow("Tab", false, false), false);
});

test("Enter and Tab activate an engaged composer row", () => {
  assert.equal(shouldPickComposerRow("Enter", false, true), true);
  assert.equal(shouldPickComposerRow("Tab", false, true), true);
  assert.equal(shouldPickComposerRow("Enter", true, true), false);
  assert.equal(shouldPickComposerRow("ArrowDown", false, true), false);
});
