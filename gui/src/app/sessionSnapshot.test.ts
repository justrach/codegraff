import { expect, test } from "bun:test";

import { getPromptDraftKey, getWorkspaceDraftKey } from "./sessionSnapshot";

test("conversation draft keys are scoped by workspace and conversation", () => {
  const first = getPromptDraftKey("/workspace/first", "shared-id");
  const second = getPromptDraftKey("/workspace/second", "shared-id");

  expect(first).not.toBe(second);
  expect(first).toBe('conversation:["/workspace/first","shared-id"]');
  expect(second).toBe('conversation:["/workspace/second","shared-id"]');
});

test("conversation draft keys cannot collide through delimiter-like values", () => {
  const first = getPromptDraftKey("/workspace/a::chat", "b");
  const second = getPromptDraftKey("/workspace/a", "chat::b");

  expect(first).not.toBe(second);
});

test("workspace-only drafts retain their workspace scope", () => {
  expect(getPromptDraftKey("/workspace/first", null)).toBe(
    getWorkspaceDraftKey("/workspace/first"),
  );
  expect(getPromptDraftKey(null, null)).toBeNull();
});
