import {
  getConversationSummary,
  getConversationView,
  sessionStore,
} from "./sessionStore";
import type { QueuedPromptEntry } from "./types/sessionStore";
import type { ChatBinding } from "@/services/desktop/types/contracts";

const drainingPromptKeys = new Set<string>();

export function tryBeginPromptQueueDrain(
  promptDraftKey: string,
  binding: ChatBinding,
): QueuedPromptEntry | null {
  if (drainingPromptKeys.has(promptDraftKey)) {
    return null;
  }

  const state = sessionStore.getState();
  const view = getConversationView(binding);
  const isKnownRunning =
    (view?.activeRequestIds.length ?? 0) > 0 ||
    (getConversationSummary(binding)?.isRunning ?? false);
  const draft = state.promptDraftsByKey[promptDraftKey] ?? null;
  const queue = state.queuedPromptsByKey[promptDraftKey] ?? [];
  if (
    isKnownRunning ||
    queue.length === 0 ||
    (draft?.isPending ?? false) ||
    (draft?.value ?? "").trim().length > 0
  ) {
    return null;
  }

  drainingPromptKeys.add(promptDraftKey);
  const next = sessionStore.getState().dequeuePrompt(promptDraftKey);
  if (next == null) {
    drainingPromptKeys.delete(promptDraftKey);
    return null;
  }

  return next;
}

export function finishPromptQueueDrain(promptDraftKey: string): void {
  drainingPromptKeys.delete(promptDraftKey);
}
