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
import type { SubmitPromptInput } from "@/app/types/sessionContext";
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
      } catch {
        sessionStore.getState().removeOptimisticRequest(
          target,
          optimisticRequestId,
        );
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
        const activeRequestCount =
          getConversationView(target)?.activeRequestIds.length ?? 0;
        if (activeRequestCount > 0) {
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
        const promptSettings = await updateWorkspacePromptSettings(workspacePath, input);
        if (promptSettings == null) {
          throw new Error("Failed to update prompt settings");
        }
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
