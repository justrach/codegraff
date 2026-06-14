import type { TranscriptMessage } from "@/services/desktop/types/contracts";

// Limit-based interrupts (tool-failure / request / end-hook) surface as the
// conversation's final "Interrupted" status, and their reason always starts
// with this prefix (see format_interruption in src-tauri/src/dto/chat.rs).
// User-initiated stops use a different reason, so they are excluded — we only
// offer "Continue" when the agent stopped itself against a limit.
const INTERRUPT_REASON_PREFIX = "Stopped after reaching";

export interface ConversationInterrupt {
  id: string;
  reason: string;
}

export function getActiveInterrupt(
  messages: TranscriptMessage[],
): ConversationInterrupt | null {
  const last = messages.at(-1);
  if (last == null || last.kind !== "status") {
    return null;
  }

  const reason = last.subtitle ?? "";
  if (last.title !== "Interrupted" || !reason.startsWith(INTERRUPT_REASON_PREFIX)) {
    return null;
  }

  return { id: last.id, reason };
}

export interface PlanDecisionAssistantInput {
  messages: TranscriptMessage[];
  requestAgentIds: Record<string, string>;
  dismissedPlanDecisionId: string | null;
}

export function getPlanDecisionAssistant({
  messages,
  requestAgentIds,
  dismissedPlanDecisionId,
}: PlanDecisionAssistantInput): TranscriptMessage | null {
  const lastAssistant = [...messages]
    .reverse()
    .find((message) => message.kind === "assistant");
  if (lastAssistant == null) {
    return null;
  }

  const lastConversationMessage = [...messages]
    .reverse()
    .find(
      (message) => message.kind === "assistant" || message.kind === "user",
    );
  if (lastConversationMessage?.id !== lastAssistant.id) {
    return null;
  }

  if (
    requestAgentIds[lastAssistant.requestId] !== "muse" ||
    lastAssistant.id === dismissedPlanDecisionId
  ) {
    return null;
  }

  return lastAssistant;
}
