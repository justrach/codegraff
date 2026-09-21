import { expect, test } from "bun:test";
import { collapsedFooterFocus, sequentialFocusIds } from "./rail-tab-sequence";

test("collapsed footer is not in the keyboard sequence after visible icons", () => {
  const hide = collapsedFooterFocus(true);
  const expand = collapsedFooterFocus(false);
  const sequence = sequentialFocusIds([
    { id: "workspace", ...hide },
    { id: "collapse", ...hide },
    { id: "expand", tabIndex: expand.tabIndex },
    { id: "new-chat", tabIndex: 0 },
    { id: "home", tabIndex: 0 },
    { id: "conversations", tabIndex: 0 },
    { id: "history", ...hide },
    { id: "account", ...hide },
    { id: "settings", ...hide },
  ]);
  expect(hide.tabIndex).toBe(-1);
  expect(hide.inert).toBe(true);
  expect(hide["aria-hidden"]).toBe(true);
  expect(sequence).toEqual(["expand", "new-chat", "home", "conversations"]);
  expect(sequence.at(-1)).toBe("conversations");
  expect(sequence).not.toContain("account");
  expect(sequence).not.toContain("settings");
  expect(sequence).not.toContain("history");
});

test("expanded footer stays after the visible icons", () => {
  const show = collapsedFooterFocus(false);
  const sequence = sequentialFocusIds([
    { id: "conversations", tabIndex: 0 },
    { id: "account", ...show },
    { id: "settings", ...show },
  ]);
  expect(show.tabIndex).toBe(0);
  expect(show.inert).toBe(false);
  expect(sequence).toEqual(["conversations", "account", "settings"]);
});
