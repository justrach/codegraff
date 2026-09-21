import { expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { DESKTOP_SHORTCUTS, shortcutHelpText } from "./desktop-shortcuts-help";

test("onboarding lists the shortcuts the desktop actually binds", () => {
  const src = readFileSync(join(import.meta.dir, "../components/site/useDesktopShortcuts.ts"), "utf8");
  expect(DESKTOP_SHORTCUTS.map(row => row.action)).toEqual([
    "New chat", "Close chat", "Reopen closed chat", "Split view", "Split right",
    "Focus prompt", "Toggle sidebar", "Cycle panes", "Cycle chats",
  ]);
  expect(src).toContain("case 'new'");
  expect(src).toContain("case 'close'");
  expect(src).toContain("case 'reopen'");
  expect(src).toContain("case 'focus-prompt'");
  expect(src).toContain("graff-toggle-sidebar");
  expect(src).toContain("k==='\\\\'");
  expect(shortcutHelpText()).toContain("New chat — ⌘T");
  expect(shortcutHelpText()).toContain("Toggle sidebar — ⌘B");
});
