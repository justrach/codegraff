import { expect, test } from "bun:test";

import type { Attachment } from "./attachments/attachmentTypes";
import {
  getPromptHistoryNavigationResult,
  type PromptHistoryCursor,
  type PromptHistoryEntry,
} from "./promptHistoryNavigation";

function history(...drafts: string[]): PromptHistoryEntry[] {
  return drafts.map((draft) => ({ attachments: [], draft }));
}

const attachment: Attachment = {
  id: "/tmp/example.png",
  path: "/tmp/example.png",
  name: "example.png",
  ext: "png",
  kind: "image" as const,
};

test("returns null when navigating previous with empty history", () => {
  expect(
    getPromptHistoryNavigationResult({
      direction: "previous",
      promptHistory: [],
      cursor: null,
      currentDraft: "draft",
      currentAttachments: [],
      draftBeforeHistory: "",
      attachmentsBeforeHistory: [],
    }),
  ).toBeNull();
});

test("returns newest prompt when navigating previous from a draft", () => {
  expect(
    getPromptHistoryNavigationResult({
      direction: "previous",
      promptHistory: history("first", "second", "third"),
      cursor: null,
      currentDraft: "draft in progress",
      currentAttachments: [],
      draftBeforeHistory: "",
      attachmentsBeforeHistory: [],
    }),
  ).toEqual({
    cursor: 2,
    draft: "third",
    attachments: [],
    draftBeforeHistory: "draft in progress",
    attachmentsBeforeHistory: [],
  });
});

test("walks backward and forward through history before restoring draft", () => {
  const promptHistory = history("first", "second", "third");

  let cursor: PromptHistoryCursor = null;
  let draft = "draft in progress";
  let attachments: Attachment[] = [attachment];
  let draftBeforeHistory = "";
  let attachmentsBeforeHistory: Attachment[] = [];

  let result = getPromptHistoryNavigationResult({
    direction: "previous",
    promptHistory,
    cursor,
    currentDraft: draft,
    currentAttachments: attachments,
    draftBeforeHistory,
    attachmentsBeforeHistory,
  });
  expect(result).toEqual({
    cursor: 2,
    draft: "third",
    attachments: [],
    draftBeforeHistory: "draft in progress",
    attachmentsBeforeHistory: [attachment],
  });

  cursor = result!.cursor;
  draft = result!.draft;
  attachments = result!.attachments;
  draftBeforeHistory = result!.draftBeforeHistory;
  attachmentsBeforeHistory = result!.attachmentsBeforeHistory;

  result = getPromptHistoryNavigationResult({
    direction: "previous",
    promptHistory,
    cursor,
    currentDraft: draft,
    currentAttachments: attachments,
    draftBeforeHistory,
    attachmentsBeforeHistory,
  });
  expect(result).toEqual({
    cursor: 1,
    draft: "second",
    attachments: [],
    draftBeforeHistory: "draft in progress",
    attachmentsBeforeHistory: [attachment],
  });

  cursor = result!.cursor;
  draft = result!.draft;
  attachments = result!.attachments;
  draftBeforeHistory = result!.draftBeforeHistory;
  attachmentsBeforeHistory = result!.attachmentsBeforeHistory;

  result = getPromptHistoryNavigationResult({
    direction: "next",
    promptHistory,
    cursor,
    currentDraft: draft,
    currentAttachments: attachments,
    draftBeforeHistory,
    attachmentsBeforeHistory,
  });
  expect(result).toEqual({
    cursor: 2,
    draft: "third",
    attachments: [],
    draftBeforeHistory: "draft in progress",
    attachmentsBeforeHistory: [attachment],
  });

  cursor = result!.cursor;
  draft = result!.draft;
  attachments = result!.attachments;
  draftBeforeHistory = result!.draftBeforeHistory;
  attachmentsBeforeHistory = result!.attachmentsBeforeHistory;

  result = getPromptHistoryNavigationResult({
    direction: "next",
    promptHistory,
    cursor,
    currentDraft: draft,
    currentAttachments: attachments,
    draftBeforeHistory,
    attachmentsBeforeHistory,
  });
  expect(result).toEqual({
    cursor: null,
    draft: "draft in progress",
    attachments: [attachment],
    draftBeforeHistory: "",
    attachmentsBeforeHistory: [],
  });
});

test("keeps previous navigation pinned at oldest prompt", () => {
  expect(
    getPromptHistoryNavigationResult({
      direction: "previous",
      promptHistory: history("first", "second", "third"),
      cursor: 0,
      currentDraft: "first",
      currentAttachments: [],
      draftBeforeHistory: "draft in progress",
      attachmentsBeforeHistory: [],
    }),
  ).toEqual({
    cursor: 0,
    draft: "first",
    attachments: [],
    draftBeforeHistory: "draft in progress",
    attachmentsBeforeHistory: [],
  });
});

test("preserves duplicate prompts as separate history entries", () => {
  const promptHistory = history("same", "different", "same");

  let result = getPromptHistoryNavigationResult({
    direction: "previous",
    promptHistory,
    cursor: null,
    currentDraft: "draft",
    currentAttachments: [],
    draftBeforeHistory: "",
    attachmentsBeforeHistory: [],
  });
  expect(result).toMatchObject({
    cursor: 2,
    draft: "same",
    draftBeforeHistory: "draft",
  });

  result = getPromptHistoryNavigationResult({
    direction: "previous",
    promptHistory,
    cursor: result!.cursor,
    currentDraft: result!.draft,
    currentAttachments: result!.attachments,
    draftBeforeHistory: result!.draftBeforeHistory,
    attachmentsBeforeHistory: result!.attachmentsBeforeHistory,
  });
  expect(result).toMatchObject({
    cursor: 1,
    draft: "different",
    draftBeforeHistory: "draft",
  });

  result = getPromptHistoryNavigationResult({
    direction: "previous",
    promptHistory,
    cursor: result!.cursor,
    currentDraft: result!.draft,
    currentAttachments: result!.attachments,
    draftBeforeHistory: result!.draftBeforeHistory,
    attachmentsBeforeHistory: result!.attachmentsBeforeHistory,
  });
  expect(result).toMatchObject({
    cursor: 0,
    draft: "same",
    draftBeforeHistory: "draft",
  });
});

test("restores attachments from a historical prompt", () => {
  expect(
    getPromptHistoryNavigationResult({
      direction: "previous",
      promptHistory: [{ draft: "see image", attachments: [attachment] }],
      cursor: null,
      currentDraft: "",
      currentAttachments: [],
      draftBeforeHistory: "",
      attachmentsBeforeHistory: [],
    }),
  ).toEqual({
    cursor: 0,
    draft: "see image",
    attachments: [attachment],
    draftBeforeHistory: "",
    attachmentsBeforeHistory: [],
  });
});
