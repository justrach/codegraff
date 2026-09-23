import { test } from "node:test";
import assert from "node:assert/strict";
import { focusNavigationPrompt, type NavigationPrompt } from "./navigation-prompt-focus.ts";

function prompt(value: string, options: { disabled?: boolean; visible?: boolean } = {}) {
  const calls: { focused: boolean; selection: [number, number] | null } = { focused: false, selection: null };
  const target: NavigationPrompt = {
    disabled: options.disabled ?? false,
    value,
    getClientRects: () => ({ length: options.visible === false ? 0 : 1 }),
    focus: () => { calls.focused = true; },
    setSelectionRange: (start, end) => { calls.selection = [start, end]; },
  };
  return { target, calls };
}

test("chat navigation focuses the composer with the caret at the end of its draft", () => {
  const { target, calls } = prompt("continue here");
  assert.equal(focusNavigationPrompt(target), true);
  assert.equal(calls.focused, true);
  assert.deepEqual(calls.selection, [13, 13]);
});

test("chat navigation leaves disabled or hidden composers untouched", () => {
  for (const options of [{ disabled: true }, { visible: false }]) {
    const { target, calls } = prompt("draft", options);
    assert.equal(focusNavigationPrompt(target), false);
    assert.equal(calls.focused, false);
    assert.equal(calls.selection, null);
  }
});
