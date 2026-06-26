import type { Attachment } from "./attachments/attachmentTypes";

export type PromptHistoryCursor = number | null;

export type PromptHistoryNavigationDirection = "previous" | "next";

export interface PromptHistoryEntry {
  attachments: Attachment[];
  draft: string;
}

export interface PromptHistoryNavigationInput {
  direction: PromptHistoryNavigationDirection;
  promptHistory: PromptHistoryEntry[];
  cursor: PromptHistoryCursor;
  currentDraft: string;
  currentAttachments: Attachment[];
  draftBeforeHistory: string;
  attachmentsBeforeHistory: Attachment[];
}

export interface PromptHistoryNavigationResult {
  cursor: PromptHistoryCursor;
  draft: string;
  attachments: Attachment[];
  draftBeforeHistory: string;
  attachmentsBeforeHistory: Attachment[];
}

export function getPromptHistoryNavigationResult({
  direction,
  promptHistory,
  cursor,
  currentDraft,
  currentAttachments,
  draftBeforeHistory,
  attachmentsBeforeHistory,
}: PromptHistoryNavigationInput): PromptHistoryNavigationResult | null {
  if (promptHistory.length === 0) {
    return null;
  }

  if (direction === "previous") {
    const nextCursor =
      cursor == null ? promptHistory.length - 1 : Math.max(0, cursor - 1);
    const entry = promptHistory[nextCursor];

    return {
      cursor: nextCursor,
      draft: entry?.draft ?? currentDraft,
      attachments: entry?.attachments ?? currentAttachments,
      draftBeforeHistory: cursor == null ? currentDraft : draftBeforeHistory,
      attachmentsBeforeHistory:
        cursor == null ? currentAttachments : attachmentsBeforeHistory,
    };
  }

  if (cursor == null) {
    return null;
  }

  const nextCursor = cursor + 1;
  if (nextCursor >= promptHistory.length) {
    return {
      cursor: null,
      draft: draftBeforeHistory,
      attachments: attachmentsBeforeHistory,
      draftBeforeHistory: "",
      attachmentsBeforeHistory: [],
    };
  }

  const entry = promptHistory[nextCursor];
  return {
    cursor: nextCursor,
    draft: entry?.draft ?? currentDraft,
    attachments: entry?.attachments ?? currentAttachments,
    draftBeforeHistory,
    attachmentsBeforeHistory,
  };
}
