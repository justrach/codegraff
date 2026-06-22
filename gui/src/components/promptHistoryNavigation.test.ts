import { expect, test } from "bun:test";

import {
  getPromptHistoryNavigationResult,
  type PromptHistoryCursor,
} from "./promptHistoryNavigation";

test("returns null when navigating previous with empty history", () => {
  expect(
    getPromptHistoryNavigationResult({
      direction: "previous",
      promptHistory: [],
      cursor: null,
      currentDraft: "draft",
      draftBeforeHistory: "",
    }),
  ).toBeNull();
});

test("returns newest prompt when navigating previous from a draft", () => {
  expect(
    getPromptHistoryNavigationResult({
      direction: "previous",
      promptHistory: ["first", "second", "third"],
      cursor: null,
      currentDraft: "draft in progress",
      draftBeforeHistory: "",
    }),
  ).toEqual({
    cursor: 2,
    draft: "third",
    draftBeforeHistory: "draft in progress",
  });
});

test("walks backward and forward through history before restoring draft", () => {
  const promptHistory = ["first", "second", "third"];

  let cursor: PromptHistoryCursor = null;
  let draft = "draft in progress";
  let draftBeforeHistory = "";

  let result = getPromptHistoryNavigationResult({
    direction: "previous",
    promptHistory,
    cursor,
    currentDraft: draft,
    draftBeforeHistory,
  });
  expect(result).toEqual({
    cursor: 2,
    draft: "third",
    draftBeforeHistory: "draft in progress",
  });

  cursor = result!.cursor;
  draft = result!.draft;
  draftBeforeHistory = result!.draftBeforeHistory;

  result = getPromptHistoryNavigationResult({
    direction: "previous",
    promptHistory,
    cursor,
    currentDraft: draft,
    draftBeforeHistory,
  });
  expect(result).toEqual({
    cursor: 1,
    draft: "second",
    draftBeforeHistory: "draft in progress",
  });

  cursor = result!.cursor;
  draft = result!.draft;
  draftBeforeHistory = result!.draftBeforeHistory;

  result = getPromptHistoryNavigationResult({
    direction: "next",
    promptHistory,
    cursor,
    currentDraft: draft,
    draftBeforeHistory,
  });
  expect(result).toEqual({
    cursor: 2,
    draft: "third",
    draftBeforeHistory: "draft in progress",
  });

  cursor = result!.cursor;
  draft = result!.draft;
  draftBeforeHistory = result!.draftBeforeHistory;

  result = getPromptHistoryNavigationResult({
    direction: "next",
    promptHistory,
    cursor,
    currentDraft: draft,
    draftBeforeHistory,
  });
  expect(result).toEqual({
    cursor: null,
    draft: "draft in progress",
    draftBeforeHistory: "",
  });
});

test("keeps previous navigation pinned at oldest prompt", () => {
  expect(
    getPromptHistoryNavigationResult({
      direction: "previous",
      promptHistory: ["first", "second", "third"],
      cursor: 0,
      currentDraft: "first",
      draftBeforeHistory: "draft in progress",
    }),
  ).toEqual({
    cursor: 0,
    draft: "first",
    draftBeforeHistory: "draft in progress",
  });
});

test("preserves duplicate prompts as separate history entries", () => {
  const promptHistory = ["same", "different", "same"];

  let result = getPromptHistoryNavigationResult({
    direction: "previous",
    promptHistory,
    cursor: null,
    currentDraft: "draft",
    draftBeforeHistory: "",
  });
  expect(result).toEqual({
    cursor: 2,
    draft: "same",
    draftBeforeHistory: "draft",
  });

  result = getPromptHistoryNavigationResult({
    direction: "previous",
    promptHistory,
    cursor: result!.cursor,
    currentDraft: result!.draft,
    draftBeforeHistory: result!.draftBeforeHistory,
  });
  expect(result).toEqual({
    cursor: 1,
    draft: "different",
    draftBeforeHistory: "draft",
  });

  result = getPromptHistoryNavigationResult({
    direction: "previous",
    promptHistory,
    cursor: result!.cursor,
    currentDraft: result!.draft,
    draftBeforeHistory: result!.draftBeforeHistory,
  });
  expect(result).toEqual({
    cursor: 0,
    draft: "same",
    draftBeforeHistory: "draft",
  });
});
