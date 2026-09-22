import assert from "node:assert/strict";
import test from "node:test";
import { commandGlyph, isFullscreenShortcut, shortcutModifiers } from "./shortcut-glyph.ts";

test("shortcut labels use Command on macOS and Ctrl elsewhere", () => {
  assert.equal(commandGlyph("MacIntel"), "⌘");
  assert.equal(commandGlyph("iPhone"), "⌘");
  assert.equal(commandGlyph("Linux x86_64"), "Ctrl+");
  assert.equal(commandGlyph("Win32"), "Ctrl+");
});

test("keyboard modifiers agree with shortcut labels on all desktop platforms", () => {
  for (const platform of ["MacIntel", "Win32", "Linux x86_64"]) {
    const mac = platform === "MacIntel";
    assert.equal(shortcutModifiers({ metaKey: true, ctrlKey: false, altKey: false }, platform).command, mac);
    assert.equal(shortcutModifiers({ metaKey: false, ctrlKey: true, altKey: false }, platform).command, !mac);
    assert.equal(shortcutModifiers({ metaKey: false, ctrlKey: false, altKey: false }, platform).command, false);
    assert.deepEqual(shortcutModifiers({ metaKey: mac, ctrlKey: true, altKey: !mac }, platform), { command: true, resize: true });
    assert.equal(shortcutModifiers({ metaKey: mac, ctrlKey: !mac, altKey: false }, platform).resize, false);
  }
});

test("fullscreen keeps Control-F available for Find on Windows and Linux", () => {
  const key = { key: "f", metaKey: false, ctrlKey: true, altKey: false, shiftKey: false };
  for (const platform of ["Win32", "Linux x86_64"]) {
    assert.equal(isFullscreenShortcut(key, platform), false);
    assert.equal(isFullscreenShortcut({ ...key, key: "Enter" }, platform), true);
    assert.equal(isFullscreenShortcut({ ...key, key: "Enter", shiftKey: true }, platform), false);
  }
  assert.equal(isFullscreenShortcut({ ...key, metaKey: true }, "MacIntel"), true);
  assert.equal(isFullscreenShortcut({ ...key, metaKey: true, ctrlKey: false }, "MacIntel"), false);
});
