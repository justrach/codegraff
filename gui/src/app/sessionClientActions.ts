import * as desktopClient from "../services/desktop/client";
import type { RuntimeStatus } from "../services/desktop/types/contracts";

import { sessionStore } from "./sessionStore";
import type {
  FollowupResponseInput,
  WorkspacePromptSettingsUpdateInput,
} from "./types/sessionClientActions";

const promptSettingsUpdateSeqByWorkspace = new Map<string, number>();

export async function runWorkspaceRuntimeStatusAction(
  workspacePath: string,
  action: () => Promise<RuntimeStatus>,
) {
  try {
    const runtimeStatus = await action();
    sessionStore.getState().setWorkspaceRuntimeStatus(workspacePath, runtimeStatus);
    return runtimeStatus;
  } catch {
    return null;
  }
}

export async function openWorkspaceInTarget(
  workspacePath: string,
  targetId: string,
) {
  try {
    await desktopClient.openInTarget(workspacePath, targetId);
    return true;
  } catch {
    return false;
  }
}

export async function openWorkspacePathInTarget(
  workspacePath: string,
  targetId: string,
  path: string,
) {
  try {
    await desktopClient.openPathInTarget(workspacePath, targetId, path);
    return true;
  } catch {
    return false;
  }
}

export async function submitFollowupResponse(input: FollowupResponseInput) {
  try {
    const snapshot = await desktopClient.respondFollowup({
      cancelled: input.cancelled,
      followupId: input.followupId,
      selectedOptionIds: input.selectedOptionIds ?? null,
      text: input.text ?? null,
    });
    sessionStore.getState().applySessionSnapshot(snapshot);
    return snapshot;
  } catch {
    return null;
  }
}

export async function updateWorkspacePromptSettings(
  workspacePath: string,
  input: WorkspacePromptSettingsUpdateInput,
) {
  const requestSeq =
    (promptSettingsUpdateSeqByWorkspace.get(workspacePath) ?? 0) + 1;
  promptSettingsUpdateSeqByWorkspace.set(workspacePath, requestSeq);

  const isLatestRequest = () =>
    promptSettingsUpdateSeqByWorkspace.get(workspacePath) === requestSeq;

  try {
    const promptSettings = await desktopClient.updatePromptSettings({
      modelId: input.modelId,
      providerId: input.providerId,
      reasoningEffort: input.reasoningEffort ?? null,
      workspacePath,
    });
    if (!isLatestRequest()) {
      return promptSettings;
    }

    sessionStore.getState().setWorkspacePromptSettings(workspacePath, promptSettings);
    try {
      const runtimeStatus = await desktopClient.getRuntimeStatus(workspacePath);
      if (isLatestRequest()) {
        sessionStore.getState().setWorkspaceRuntimeStatus(workspacePath, runtimeStatus);
      }
    } catch {
      if (isLatestRequest()) {
        sessionStore.getState().setWorkspaceRuntimeStatus(workspacePath, null);
      }
    }
    return promptSettings;
  } catch {
    return null;
  }
}
