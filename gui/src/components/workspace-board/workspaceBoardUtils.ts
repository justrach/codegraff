import type { DockviewApi } from "dockview-react";

import {
  getConversationSummary,
  getWorkspaceSession,
} from "@/app/sessionStore";
import type { WorkspaceBoardSelection } from "@/app/types/sessionContext";
import type { ChatBinding } from "@/services/desktop/types/contracts";

import { createChatPanelId } from "./layout";
import type { OuterChatPanelParams } from "./types/layout";

export function getWorkspaceBoardSelectionKey(
  selection: WorkspaceBoardSelection,
): string {
  switch (selection.kind) {
    case "empty":
      return "board:empty";
    case "single-chat":
      return `board:single:${createChatPanelId(selection.chat)}`;
    case "workspace-draft":
      return `board:draft:${encodeURIComponent(selection.workspacePath)}`;
    case "saved-workspace":
      return `board:saved:${selection.workspace.id}`;
  }
}

export function getOuterPanelBinding(
  panel: { params?: unknown } | undefined,
): ChatBinding | null {
  const params = panel?.params as Partial<OuterChatPanelParams> | undefined;
  if (
    params == null ||
    typeof params.workspacePath !== "string" ||
    typeof params.conversationId !== "string"
  ) {
    return null;
  }

  return {
    workspacePath: params.workspacePath,
    conversationId: params.conversationId,
  };
}

export function getActiveOuterBinding(
  api: DockviewApi | null | undefined,
): ChatBinding | null {
  return getOuterPanelBinding(api?.activePanel);
}

export function getChatTitle(
  binding: ChatBinding,
): string {
  const workspace = getWorkspaceSession(binding.workspacePath);
  const conversation = getConversationSummary(binding);

  if (workspace == null && conversation == null) {
    return "Chat";
  }

  if (workspace == null) {
    return conversation?.title ?? "Chat";
  }

  if (conversation == null) {
    return workspace.workspaceName;
  }

  return `${workspace.workspaceName} · ${conversation.title}`;
}
