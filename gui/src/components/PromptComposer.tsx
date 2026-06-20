import { useCallback, useState } from "react";

import { useConversationSession } from "../hooks/useSession";
import { usePrompt } from "../hooks/usePrompt";
import { useCommandRouter } from "../hooks/useCommandRouter";
import { CommandResultDialog } from "./CommandResultDialog";
import { FollowupComposer } from "./FollowupComposer";
import { PromptActionAlert } from "./PromptActionAlert";
import { PromptInputCard } from "./PromptInputCard";
import { InterruptContinuePrompt } from "./conversation-panel/InterruptContinuePrompt";
import { PlanDecisionCard } from "./conversation-panel/PlanDecisionCard";
import { SessionTodoDock } from "./conversation-panel/SessionTodoDock";
import {
  getActiveInterrupt,
  getPlanDecisionAssistant,
} from "./conversation-panel/utils/interruptPrompt";
import { useSettingsNavigation } from "@/app/settingsNavigationContext";
import { sessionStore } from "@/app/sessionStore";
import * as desktopClient from "@/services/desktop/client";
import type { PromptComposerProps } from "./types/prompt";

export function PromptComposer({ binding, onCommandResult }: PromptComposerProps) {
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
  const { messages, requestAgentIds, todos } = useConversationSession(binding);
  const { openProviderSettings } = useSettingsNavigation();
  const [dismissedInterruptId, setDismissedInterruptId] = useState<string | null>(
    null,
  );
  const [dismissedPlanDecisionId, setDismissedPlanDecisionId] = useState<
    string | null
  >(null);
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
  const {
    workspacePath,
    handleCommandSelect,
    trySubmitAsCommand,
    commandResult,
    dismissCommandResult,
  } = useCommandRouter(binding, { onCommandResult });
  const requiresProviderSetup =
    promptSettings != null && promptSettings.availableModels.length === 0;
  const promptHistory = messages
    .filter((message) => message.kind === "user")
    .map((message) => message.text);

  const handleSubmit = useCallback(async () => {
    if (trySubmitAsCommand(promptDraft)) {
      return;
    }
    await submitPrompt();
  }, [promptDraft, submitPrompt, trySubmitAsCommand]);

  const handleApproveWorkflow = useCallback(
    async (prompt: string) => {
      // Saved-workspace/new-chat composers do not have a persisted chat binding
      // yet, so approval falls back to pre-filling the prompt for manual send.
      if (binding == null) {
        setPromptDraft(prompt);
        return;
      }
      const snapshot = await desktopClient.sendPrompt({
        workspacePath: binding.workspacePath,
        conversationId: binding.conversationId,
        agentId: isPlanningMode ? "muse" : "forge",
        prompt,
      });
      sessionStore.getState().applySessionSnapshot(snapshot);
      dismissCommandResult();
    },
    [binding, dismissCommandResult, isPlanningMode, setPromptDraft],
  );

  const handleContinueAfterInterrupt = useCallback(async () => {
    if (binding == null) {
      return;
    }
    const snapshot = await desktopClient.sendPrompt({
      workspacePath: binding.workspacePath,
      conversationId: binding.conversationId,
      agentId: isPlanningMode ? "muse" : "forge",
      prompt: "Continue.",
    });
    sessionStore.getState().applySessionSnapshot(snapshot);
  }, [binding, isPlanningMode]);

  const handleImplementPlan = useCallback(async () => {
    if (binding == null || lastAssistant == null) {
      return;
    }
    setPlanningMode(false);
    setDismissedPlanDecisionId(lastAssistant.id);
    const snapshot = await desktopClient.sendPrompt({
      workspacePath: binding.workspacePath,
      conversationId: binding.conversationId,
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

  return (
    <div className="px-6 pb-6">
      <SessionTodoDock isRequestActive={isRequestActive} todos={todos} />
      {interrupt != null &&
      !isRequestActive &&
      interrupt.id !== dismissedInterruptId ? (
        <InterruptContinuePrompt
          reason={interrupt.reason}
          onContinue={handleContinueAfterInterrupt}
          onDismiss={() => {
            setDismissedInterruptId(interrupt.id);
          }}
        />
      ) : null}
      {showPlanDecision ? (
        <PlanDecisionCard
          key={lastAssistant.id}
          onImplement={handleImplementPlan}
          onContinue={handleContinuePlanning}
        />
      ) : null}
      {followupRequest != null ? (
        <FollowupComposer
          key={followupRequest.followupId}
          followupRequest={followupRequest}
        />
      ) : (
        <>
          {requiresProviderSetup ? (
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
            isPlanningMode={isPlanningMode}
            promptSettings={promptSettings}
            promptDraft={promptDraft}
            promptHistory={promptHistory}
            isInputDisabled={requiresProviderSetup}
            binding={binding}
            workspacePath={workspacePath}
            onCommandSelect={handleCommandSelect}
            setPlanningMode={setPlanningMode}
            setPromptDraft={setPromptDraft}
            stopPrompt={stopPrompt}
            submitPrompt={handleSubmit}
            updatePromptSettings={updatePromptSettings}
          />
        </>
      )}
      <CommandResultDialog
        result={commandResult}
        onClose={dismissCommandResult}
        onApproveWorkflow={handleApproveWorkflow}
      />
    </div>
  );
}
