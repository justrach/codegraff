import assert from "node:assert/strict";
import test from "node:test";
import { commandGlyph } from "./shortcut-glyph.ts";

test("shortcut labels use Command on macOS and Ctrl elsewhere", () => {
  assert.equal(commandGlyph("MacIntel"), "⌘");
  assert.equal(commandGlyph("iPhone"), "⌘");
  assert.equal(commandGlyph("Linux x86_64"), "Ctrl+");
  assert.equal(commandGlyph("Win32"), "Ctrl+");
});
