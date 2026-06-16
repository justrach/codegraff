import { useMemo } from "react";

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

  return useMemo(() => {
    if (binding == null) {
      return rootActions;
    }

    const { conversationId, workspacePath } = binding;

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
      },
      submitPrompt: async () => {
        const promptDraftKey = getPromptDraftKey(workspacePath, conversationId);
        if (promptDraftKey == null) {
          return;
        }

        const draftState = getPromptDraftState(promptDraftKey);
        const trimmedPrompt = draftState.value.trim();
        if (trimmedPrompt.length === 0) {
          return;
        }

        const attachments = getAttachments(promptDraftKey);
        const prompt = appendAttachmentsToPrompt(trimmedPrompt, attachments);

        // Clear the composer immediately on send so the draft + any attachment
        // don't linger in the bar while the turn runs (the prompt is already
        // captured above).
        sessionStore.getState().clearPromptDraft(promptDraftKey);
        sessionStore.getState().clearAttachments(promptDraftKey);
        sessionStore.getState().setPromptDraftPending(promptDraftKey, true);
        try {
          const snapshot = await desktopClient.sendPrompt({
            agentId: draftState.isPlanningMode ? "muse" : "forge",
            conversationId,
            prompt,
            workspacePath,
          });
          sessionStore.getState().applySessionSnapshot(snapshot);
        } catch {
          return;
        } finally {
          sessionStore.getState().setPromptDraftPending(promptDraftKey, false);
        }
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
}
