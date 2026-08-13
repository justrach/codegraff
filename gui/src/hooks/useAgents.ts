import { useMemo } from "react";

import {
  buildAgentOverview,
  type AgentOverviewSnapshot,
} from "@/app/projections/agents";
import { getConversationStoreKey } from "@/app/sessionStore";

import { useBoardSelection, useSessionStore } from "./useSession";

/**
 * The agent-activity projection of the session store. Every surface that
 * shows agent state (the titlebar activity control today, tile badges
 * tomorrow) subscribes here instead of deriving its own view of
 * conversations, so there is exactly one definition of "what the agents are
 * doing" — the same shape the engine snapshot already normalized for us.
 */
export function useAgentOverview(): AgentOverviewSnapshot {
  const selection = useBoardSelection();
  const views = useSessionStore((state) => state.conversationViewsByKey);
  const summaries = useSessionStore(
    (state) => state.conversationSummariesByKey,
  );

  return useMemo(() => {
    const currentBinding =
      selection.kind === "single-chat"
        ? selection.chat
        : selection.kind === "saved-workspace"
          ? selection.activeChat
          : null;
    const currentConversationKey =
      currentBinding == null
        ? null
        : getConversationStoreKey(
            currentBinding.workspacePath,
            currentBinding.conversationId,
          );

    return buildAgentOverview({
      views,
      summaries,
      currentConversationKey,
    });
  }, [selection, summaries, views]);
}
