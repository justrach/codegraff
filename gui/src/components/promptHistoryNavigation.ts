export type PromptHistoryCursor = number | null;

export type PromptHistoryNavigationDirection = "previous" | "next";

export interface PromptHistoryNavigationInput {
  direction: PromptHistoryNavigationDirection;
  promptHistory: string[];
  cursor: PromptHistoryCursor;
  currentDraft: string;
  draftBeforeHistory: string;
}

export interface PromptHistoryNavigationResult {
  cursor: PromptHistoryCursor;
  draft: string;
  draftBeforeHistory: string;
}

export function getPromptHistoryNavigationResult({
  direction,
  promptHistory,
  cursor,
  currentDraft,
  draftBeforeHistory,
}: PromptHistoryNavigationInput): PromptHistoryNavigationResult | null {
  if (promptHistory.length === 0) {
    return null;
  }

  if (direction === "previous") {
    const nextCursor =
      cursor == null ? promptHistory.length - 1 : Math.max(0, cursor - 1);

    return {
      cursor: nextCursor,
      draft: promptHistory[nextCursor] ?? currentDraft,
      draftBeforeHistory: cursor == null ? currentDraft : draftBeforeHistory,
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
      draftBeforeHistory: "",
    };
  }

  return {
    cursor: nextCursor,
    draft: promptHistory[nextCursor] ?? currentDraft,
    draftBeforeHistory,
  };
}
