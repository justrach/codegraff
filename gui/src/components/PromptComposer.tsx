import { useCallback, useState } from "react";

import { useConversationSession } from "../hooks/useSession";
import { usePrompt } from "../hooks/usePrompt";
import { useCommandRouter } from "../hooks/useCommandRouter";
import { CommandResultDialog } from "./CommandResultDialog";
import { FollowupComposer } from "./FollowupComposer";
import { GoalChip } from "./GoalChip";
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

export function PromptComposer({
  binding,
  onCommandResult,
}: PromptComposerProps) {
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
  const { goal, messages, requestAgentIds, todos } =
    useConversationSession(binding);
  const { openProviderSettings } = useSettingsNavigation();
  const [dismissedInterruptId, setDismissedInterruptId] = useState<
    string | null
  >(null);
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

  // The goal chip mutates `/goal` directly (set/clear). The backend persists
  // it on the conversation and returns a fresh snapshot, which we apply so the
  // chip reflects the new state without a round-trip through the composer draft.
  const runGoalCommand = useCallback(
    (args: string[]) => {
      if (workspacePath == null || binding == null) {
        return;
      }
      void desktopClient
        .runSlashCommand({
          name: "goal",
          args,
          workspacePath,
          conversationId: binding.conversationId,
        })
        .then((result) => {
          if (result.snapshot != null) {
            sessionStore.getState().applySessionSnapshot(result.snapshot);
          }
        })
        .catch(() => null);
    },
    [binding, workspacePath],
  );
  const handleGoalEdit = useCallback(
    (next: string) => runGoalCommand([next]),
    [runGoalCommand],
  );
  const handleGoalClear = useCallback(
    () => runGoalCommand(["clear"]),
    [runGoalCommand],
  );

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
          <GoalChip
            goal={goal}
            onEdit={handleGoalEdit}
            onClear={handleGoalClear}
          />
          <PromptInputCard
            canCompose={canCompose}
            isRequestActive={isRequestActive}
            isSendingPrompt={isSendingPrompt}
            isPlanningMode={isPlanningMode}
            isUltraMode={isUltraMode}
            promptSettings={promptSettings}
            promptDraft={promptDraft}
            queuedPrompts={queuedPrompts}
            promptHistory={promptHistory}
            isInputDisabled={requiresProviderSetup}
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
