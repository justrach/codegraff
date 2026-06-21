import { useCallback, useState } from "react";

import { getUiActiveBinding, sessionStore } from "@/app/sessionStore";
import { CommandResultDialog } from "@/components/CommandResultDialog";
import { FollowupComposer } from "@/components/FollowupComposer";
import { PromptInputCard } from "@/components/PromptInputCard";
import { PlanDecisionCard } from "@/components/conversation-panel/PlanDecisionCard";
import {
  getActiveInterrupt,
  getPlanDecisionAssistant,
} from "@/components/conversation-panel/utils/interruptPrompt";
import { usePrompt } from "@/hooks/usePrompt";
import { useCommandRouter } from "@/hooks/useCommandRouter";
import { useConversationSession } from "@/hooks/useSession";
import * as desktopClient from "@/services/desktop/client";
import type {
  ChatBinding,
  CommandRunResult,
} from "@/services/desktop/types/contracts";

export function NewChatPromptSection({
  binding,
  focusSignal,
  onCommandResult,
}: {
  binding?: ChatBinding | null;
  focusSignal?: number;
  onCommandResult?: (result: CommandRunResult) => void;
}) {
  const { hasCurrentWorkspace, messages, requestAgentIds, workspaceKind } =
    useConversationSession(binding);
  const {
    canCompose,
    followupRequest,
    isPlanningMode,
    isRequestActive,
    isSendingPrompt,
    isUltraMode,
    promptSettings,
    promptDraft,
    queuedPrompts,
    setPlanningMode,
    setPromptDraft,
    setUltraMode,
    stopPrompt,
    submitPrompt,
    updatePromptSettings,
  } = usePrompt(binding);
  const [dismissedPlanDecisionId, setDismissedPlanDecisionId] = useState<
    string | null
  >(null);
  const {
    workspacePath,
    handleCommandSelect,
    trySubmitAsCommand,
    commandResult,
    dismissCommandResult,
  } = useCommandRouter(binding, { onCommandResult });
  const interrupt = getActiveInterrupt(messages);
  const lastAssistant = getPlanDecisionAssistant({
    messages,
    requestAgentIds,
    dismissedPlanDecisionId,
  });
  const showPlanDecision =
    !isRequestActive &&
    followupRequest == null &&
    interrupt == null &&
    lastAssistant != null;
  const promptHistory = messages
    .filter((message) => message.kind === "user")
    .map((message) => message.text);
  const handleSubmit = useCallback(
    async (draftOverride?: string) => {
      const draft = draftOverride ?? promptDraft;
      if (draftOverride != null) {
        setPromptDraft(draftOverride);
      }
      if (trySubmitAsCommand(draft)) {
        return;
      }
      await submitPrompt(draftOverride);
    },
    [promptDraft, setPromptDraft, submitPrompt, trySubmitAsCommand],
  );
  const handleImplementPlan = useCallback(async () => {
    if (lastAssistant == null) {
      return;
    }

    const activeBinding =
      binding ?? getUiActiveBinding(sessionStore.getState());
    if (activeBinding == null) {
      return;
    }

    setPlanningMode(false);
    setDismissedPlanDecisionId(lastAssistant.id);
    const snapshot = await desktopClient.sendPrompt({
      workspacePath: activeBinding.workspacePath,
      conversationId: activeBinding.conversationId,
      agentId: "forge",
      prompt: "Implement the plan above.",
    });
    sessionStore.getState().applySessionSnapshot(snapshot);
  }, [binding, lastAssistant, setPlanningMode]);
  const handleContinuePlanning = useCallback(() => {
    if (lastAssistant != null) {
      setDismissedPlanDecisionId(lastAssistant.id);
    }
  }, [lastAssistant]);
  if (followupRequest != null) {
    return (
      <FollowupComposer
        key={followupRequest.followupId}
        followupRequest={followupRequest}
      />
    );
  }

  return (
    <>
      {showPlanDecision ? (
        <PlanDecisionCard
          key={lastAssistant.id}
          onImplement={handleImplementPlan}
          onContinue={handleContinuePlanning}
        />
      ) : null}
      <PromptInputCard
        canCompose={canCompose}
        focusSignal={focusSignal}
        isRequestActive={isRequestActive}
        isSendingPrompt={isSendingPrompt}
        placeholder={
          workspaceKind === "managed_chat"
            ? "Ask anything…"
            : hasCurrentWorkspace
              ? "Ask about this workspace…"
              : "Ask anything…"
        }
        isPlanningMode={isPlanningMode}
        isUltraMode={isUltraMode}
        promptDraft={promptDraft}
        queuedPrompts={queuedPrompts}
        promptHistory={promptHistory}
        promptSettings={promptSettings}
        isInputDisabled={!hasCurrentWorkspace}
        binding={binding}
        workspacePath={workspacePath}
        onCommandSelect={handleCommandSelect}
        setPlanningMode={setPlanningMode}
        setUltraMode={setUltraMode}
        setPromptDraft={setPromptDraft}
        stopPrompt={stopPrompt}
        submitPrompt={handleSubmit}
        updatePromptSettings={updatePromptSettings}
      />
      <CommandResultDialog
        result={commandResult}
        onClose={dismissCommandResult}
      />
    </>
  );
}
