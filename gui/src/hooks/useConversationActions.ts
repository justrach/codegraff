import { useEffect, useMemo, useRef } from "react";

import {
  openWorkspaceInTarget,
  runWorkspaceRuntimeStatusAction,
  submitFollowupResponse,
  updateWorkspacePromptSettings,
} from "@/app/sessionClientActions";
import {
  getAttachments,
  getConversationView,
  getPromptDraftState,
  sessionStore,
} from "@/app/sessionStore";
import { getPromptDraftKey } from "@/app/sessionSnapshot";
import { appendAttachmentsToPrompt } from "@/components/attachments/attachmentTypes";
import * as desktopClient from "@/services/desktop/client";
import type { ChatBinding } from "@/services/desktop/types/contracts";

import { useSessionActions } from "./useSession";

export function useConversationActions(binding?: ChatBinding | null) {
  const rootActions = useSessionActions();
  const queuedDrainRunningRef = useRef(false);

  const actions = useMemo(() => {
    if (binding == null) {
      return rootActions;
    }

    const { conversationId, workspacePath } = binding;
    const promptDraftKey = getPromptDraftKey(workspacePath, conversationId);

    const restorePromptDraft = (
      value: string,
      isPlanningMode: boolean,
      isUltraMode: boolean,
      attachments: ReturnType<typeof getAttachments>,
    ) => {
      if (promptDraftKey == null) {
        return;
      }
      const store = sessionStore.getState();
      store.setPromptDraftValue(promptDraftKey, value);
      store.setPromptDraftPlanningMode(promptDraftKey, isPlanningMode);
      store.setPromptDraftUltraMode(promptDraftKey, isUltraMode);
      store.clearAttachments(promptDraftKey);
      store.addAttachments(promptDraftKey, attachments);
    };

    const submitCapturedPrompt = async (
      value: string,
      isPlanningMode: boolean,
      isUltraMode: boolean,
      attachments: ReturnType<typeof getAttachments>,
    ) => {
      if (promptDraftKey == null) {
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
      store.clearPromptDraft(promptDraftKey);
      store.setPromptDraftUltraMode(promptDraftKey, false);
      store.clearAttachments(promptDraftKey);
      store.setPromptDraftPending(promptDraftKey, true);
      try {
        const snapshot = await desktopClient.sendPrompt({
          agentId: isPlanningMode ? "muse" : "forge",
          conversationId,
          prompt,
          workspacePath,
        });
        sessionStore.getState().applySessionSnapshot(snapshot);
      } catch {
        restorePromptDraft(value, isPlanningMode, isUltraMode, attachments);
        return;
      } finally {
        sessionStore.getState().setPromptDraftPending(promptDraftKey, false);
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
      submitPrompt: async (draftOverride?: string) => {
        if (promptDraftKey == null) {
          return;
        }

        const draftState = getPromptDraftState(promptDraftKey);
        const draftValue = draftOverride ?? draftState.value;
        const trimmedPrompt = draftValue.trim();
        if (trimmedPrompt.length === 0) {
          return;
        }

        const attachments = getAttachments(promptDraftKey);
        const activeRequestCount =
          getConversationView(binding)?.activeRequestIds.length ?? 0;
        if (activeRequestCount > 0) {
          const store = sessionStore.getState();
          store.enqueuePrompt(promptDraftKey, {
            attachments,
            isPlanningMode: draftState.isPlanningMode,
            isUltraMode: draftState.isUltraMode,
            value: trimmedPrompt,
          });
          store.clearPromptDraft(promptDraftKey);
          store.setPromptDraftUltraMode(promptDraftKey, false);
          store.clearAttachments(promptDraftKey);
          return;
        }

        await submitCapturedPrompt(
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

    return sessionStore.subscribe((state) => {
      if (queuedDrainRunningRef.current) {
        return;
      }

      const view = getConversationView(binding);
      const activeRequestCount = view?.activeRequestIds.length ?? 0;
      const draft = state.promptDraftsByKey[promptDraftKey] ?? null;
      const queue = state.queuedPromptsByKey[promptDraftKey] ?? [];
      if (
        activeRequestCount > 0 ||
        queue.length === 0 ||
        (draft?.isPending ?? false) ||
        (draft?.value ?? "").trim().length > 0
      ) {
        return;
      }

      const next = sessionStore.getState().dequeuePrompt(promptDraftKey);
      if (next == null) {
        return;
      }

      const store = sessionStore.getState();
      store.setPromptDraftValue(promptDraftKey, next.value);
      store.setPromptDraftPlanningMode(promptDraftKey, next.isPlanningMode);
      store.setPromptDraftUltraMode(promptDraftKey, next.isUltraMode);
      store.clearAttachments(promptDraftKey);
      store.addAttachments(promptDraftKey, next.attachments);
      queuedDrainRunningRef.current = true;
      queueMicrotask(() => {
        void actions.submitPrompt().finally(() => {
          queuedDrainRunningRef.current = false;
        });
      });
    });
  }, [actions, binding]);

  return actions;
}
