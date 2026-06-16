import { useCallback, useState } from "react";

import { useSettingsNavigation } from "@/app/settingsNavigationContext";
import { getUiActiveBinding, sessionStore } from "@/app/sessionStore";
import { CommandResultDialog } from "@/components/CommandResultDialog";
import { FollowupComposer } from "@/components/FollowupComposer";
import { PromptActionAlert } from "@/components/PromptActionAlert";
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
  onCommandResult,
}: {
  binding?: ChatBinding | null;
  onCommandResult?: (result: CommandRunResult) => void;
}) {
  const {
    hasCurrentWorkspace,
    messages,
    requestAgentIds,
    workspaceKind,
  } = useConversationSession(binding);
  const {
    canCompose,
    followupRequest,
    isPlanningMode,
    isRequestActive,
    isSendingPrompt,
    promptSettings,
    promptDraft,
    setPlanningMode,
    setPromptDraft,
    stopPrompt,
    submitPrompt,
    updatePromptSettings,
  } = usePrompt(binding);
  const { openProviderSettings } = useSettingsNavigation();
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
  const handleSubmit = useCallback(async () => {
    if (trySubmitAsCommand(promptDraft)) {
      return;
    }
    await submitPrompt();
  }, [promptDraft, submitPrompt, trySubmitAsCommand]);
  const handleImplementPlan = useCallback(async () => {
    if (lastAssistant == null) {
      return;
    }

    const activeBinding = binding ?? getUiActiveBinding(sessionStore.getState());
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
  const showProviderSetupPrompt =
    hasCurrentWorkspace &&
    promptSettings != null &&
    promptSettings.availableModels.length === 0;

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
      {showProviderSetupPrompt ? (
        <PromptActionAlert
          title="No provider is configured"
          description="Configure at least one provider to start chatting."
          actionLabel="Configure"
          onAction={openProviderSettings}
        />
      ) : null}
      <PromptInputCard
        canCompose={canCompose}
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
        promptDraft={promptDraft}
        promptSettings={promptSettings}
        isInputDisabled={showProviderSetupPrompt}
        binding={binding}
        workspacePath={workspacePath}
        onCommandSelect={handleCommandSelect}
        setPlanningMode={setPlanningMode}
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
