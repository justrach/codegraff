import { useEffect, useMemo } from "react";

import {
  openWorkspaceInTarget,
  runWorkspaceRuntimeStatusAction,
  submitFollowupResponse,
  updateWorkspacePromptSettings,
} from "@/app/sessionClientActions";
import {
  getAttachments,
  getConversationSummary,
  getConversationView,
  getPromptDraftState,
  sessionStore,
} from "@/app/sessionStore";
import { getPromptDraftKey } from "@/app/sessionSnapshot";
import { appendAttachmentsToPrompt } from "@/components/attachments/attachmentTypes";
import {
  isActivePromptConflictError,
  snapshotHasActiveRequest,
} from "@/app/promptSubmitErrors";
import {
  finishPromptQueueDrain,
  tryBeginPromptQueueDrain,
} from "@/app/promptQueueDrain";
import * as desktopClient from "@/services/desktop/client";
import type { SubmitPromptInput } from "@/app/types/sessionContext";
import type { ChatBinding } from "@/services/desktop/types/contracts";

import { useSessionActions } from "./useSession";

export function useConversationActions(binding?: ChatBinding | null) {
  const rootActions = useSessionActions();

  const actions = useMemo(() => {
    if (binding == null) {
      return rootActions;
    }

    const { conversationId, workspacePath } = binding;
    const promptDraftKey = getPromptDraftKey(workspacePath, conversationId);

    const restorePromptDraft = (
      key: string | null,
      value: string,
      isPlanningMode: boolean,
      isUltraMode: boolean,
      attachments: ReturnType<typeof getAttachments>,
    ) => {
      if (key == null) {
        return;
      }
      const store = sessionStore.getState();
      store.setPromptDraftValue(key, value);
      store.setPromptDraftPlanningMode(key, isPlanningMode);
      store.setPromptDraftUltraMode(key, isUltraMode);
      store.clearAttachments(key);
      store.addAttachments(key, attachments);
    };

    const submitCapturedPrompt = async (
      target: ChatBinding,
      key: string | null,
      value: string,
      isPlanningMode: boolean,
      isUltraMode: boolean,
      attachments: ReturnType<typeof getAttachments>,
    ) => {
      if (key == null) {
        return;
      }

      let prompt = appendAttachmentsToPrompt(value.trim(), attachments);

      // Ultra mode: inject the `ultracode` codeword the harness watches for
      // (case-insensitive substring -> multi-agent workflow turn). Skip it if
      // the user already typed it. The toggle is a per-turn opt-in, so it is
      // reset below once the prompt has been captured.
      if (isUltraMode && !/ultracode/i.test(prompt)) {
        prompt = `${prompt}\n\nultracode`;
      }

      const store = sessionStore.getState();
      store.clearPromptDraft(key);
      store.setPromptDraftUltraMode(key, false);
      store.clearAttachments(key);
      store.setPromptDraftPending(key, true);
      const optimisticRequestId = `optimistic-${Date.now()}`;
      const agentId = isPlanningMode ? "muse" : "forge";
      store.appendOptimisticUserMessage(
        target,
        optimisticRequestId,
        prompt,
        agentId,
      );
      try {
        const snapshot = await desktopClient.sendPrompt({
          agentId,
          conversationId: target.conversationId,
          prompt,
          workspacePath: target.workspacePath,
        });
        sessionStore.getState().applySessionSnapshot(snapshot);
      } catch (error) {
        const currentStore = sessionStore.getState();
        currentStore.removeOptimisticRequest(target, optimisticRequestId);
        if (isActivePromptConflictError(error)) {
          const snapshot = await desktopClient.getSessionSnapshot().catch(() => null);
          if (snapshot != null) {
            sessionStore.getState().applySessionSnapshot(snapshot);
          }
          if (snapshotHasActiveRequest(snapshot, target)) {
            sessionStore.getState().enqueuePrompt(key, {
              attachments,
              isPlanningMode,
              isUltraMode,
              value,
            });
            return;
          }
        }
        restorePromptDraft(key, value, isPlanningMode, isUltraMode, attachments);
        return;
      } finally {
        sessionStore.getState().setPromptDraftPending(key, false);
      }
    };

    return {
      ...rootActions,
      checkoutBranch: async (branchName: string) => {
        await runWorkspaceRuntimeStatusAction(workspacePath, () =>
          desktopClient.checkoutGitBranch({
            branchName,
            workspacePath,
          }),
        );
      },
      commitChanges: async (message: string) => {
        await runWorkspaceRuntimeStatusAction(workspacePath, () =>
          desktopClient.commitGitChanges({
            message,
            workspacePath,
          }),
        );
      },
      createBranch: async (branchName: string) => {
        await runWorkspaceRuntimeStatusAction(workspacePath, () =>
          desktopClient.createGitBranch({
            branchName,
            workspacePath,
          }),
        );
      },
      openInTarget: async (targetId: string) => {
        await openWorkspaceInTarget(workspacePath, targetId);
      },
      pushBranch: async () => {
        await runWorkspaceRuntimeStatusAction(workspacePath, () =>
          desktopClient.pushGitBranch(workspacePath),
        );
      },
      submitFollowup: async (input: {
        cancelled: boolean;
        text?: string;
        selectedOptionIds?: string[];
      }) => {
        const followupRequest = getConversationView(binding)?.followup ?? null;
        if (followupRequest == null) {
          return;
        }

        await submitFollowupResponse({
          cancelled: input.cancelled,
          followupId: followupRequest.followupId,
          selectedOptionIds: input.selectedOptionIds,
          text: input.text,
        });
      },
      stopPrompt: async () => {
        await desktopClient
          .stopPrompt({
            conversationId,
            workspacePath,
          })
          .catch(() => null);
        sessionStore.getState().setPromptDraftPending(promptDraftKey, false);
        await desktopClient
          .getSessionSnapshot()
          .then((snapshot) => {
            sessionStore.getState().applySessionSnapshot(snapshot);
          })
          .catch(() => null);
      },
      submitPrompt: async (input?: SubmitPromptInput) => {
        const target: ChatBinding =
          typeof input === "object" && input != null
            ? {
                conversationId: input.conversationId ?? conversationId,
                workspacePath: input.workspacePath ?? workspacePath,
              }
            : { conversationId, workspacePath };
        const targetPromptDraftKey = getPromptDraftKey(
          target.workspacePath,
          target.conversationId,
        );
        if (targetPromptDraftKey == null) {
          return;
        }

        const draftState = getPromptDraftState(targetPromptDraftKey);
        const draftValue = typeof input === "string" ? input : input?.draft ?? draftState.value;
        const trimmedPrompt = draftValue.trim();
        if (trimmedPrompt.length === 0) {
          return;
        }

        const attachments = getAttachments(targetPromptDraftKey);
        const targetIsKnownRunning =
          (getConversationView(target)?.activeRequestIds.length ?? 0) > 0 ||
          (getConversationSummary(target)?.isRunning ?? false);
        if (targetIsKnownRunning) {
          const store = sessionStore.getState();
          store.enqueuePrompt(targetPromptDraftKey, {
            attachments,
            isPlanningMode: draftState.isPlanningMode,
            isUltraMode: draftState.isUltraMode,
            value: trimmedPrompt,
          });
          store.clearPromptDraft(targetPromptDraftKey);
          store.setPromptDraftUltraMode(targetPromptDraftKey, false);
          store.clearAttachments(targetPromptDraftKey);
          return;
        }

        await submitCapturedPrompt(
          target,
          targetPromptDraftKey,
          trimmedPrompt,
          draftState.isPlanningMode,
          draftState.isUltraMode,
          attachments,
        );
      },
      updatePromptSettings: async (input: {
        providerId: string;
        modelId: string;
        reasoningEffort?: string | null;
      }) => {
        await updateWorkspacePromptSettings(workspacePath, input);
      },
    };
  }, [binding, rootActions]);

  useEffect(() => {
    if (binding == null) {
      return;
    }

    const { conversationId, workspacePath } = binding;
    const promptDraftKey = getPromptDraftKey(workspacePath, conversationId);
    if (promptDraftKey == null) {
      return;
    }

    return sessionStore.subscribe(() => {
      const next = tryBeginPromptQueueDrain(promptDraftKey, binding);
      if (next == null) {
        return;
      }

      const store = sessionStore.getState();
      store.setPromptDraftValue(promptDraftKey, next.value);
      store.setPromptDraftPlanningMode(promptDraftKey, next.isPlanningMode);
      store.setPromptDraftUltraMode(promptDraftKey, next.isUltraMode);
      store.clearAttachments(promptDraftKey);
      store.addAttachments(promptDraftKey, next.attachments);
      queueMicrotask(() => {
        void actions.submitPrompt().finally(() => {
          finishPromptQueueDrain(promptDraftKey);
        });
      });
    });
  }, [actions, binding]);

  return actions;
}
