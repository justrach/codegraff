import type {
  ChatBinding,
  ConversationViewSnapshot,
  SessionSnapshot,
} from "@/services/desktop/types/contracts";

export function isActivePromptConflictError(error: unknown): boolean {
  const message = error instanceof Error ? error.message : String(error);
  return message.toLowerCase().includes("conversation already has an active prompt");
}

export function snapshotHasActiveRequest(
  snapshot: SessionSnapshot | null,
  binding: ChatBinding,
): boolean {
  if (snapshot == null) {
    return false;
  }
  return snapshotHasActiveRequestForBinding(snapshot, binding);
}

function snapshotHasActiveRequestForBinding(
  snapshot: SessionSnapshot,
  binding: ChatBinding,
): boolean {
  if (
    snapshot.conversationViews.some(
      (view) =>
        view.workspacePath === binding.workspacePath &&
        view.conversationId === binding.conversationId &&
        view.activeRequestIds.length > 0,
    )
  ) {
    return true;
  }

  return snapshot.workspaces.some(
    (workspace) =>
      workspace.workspacePath === binding.workspacePath &&
      workspace.conversations.some(
        (conversation) =>
          conversation.conversationId === binding.conversationId &&
          conversation.isRunning,
      ),
  );
}

function viewLatestUserPromptLooksAccepted(
  view: ConversationViewSnapshot,
  prompt: string,
): boolean {
  const latestUserMessage = view.messages.findLast(
    (message) => message.kind === "user",
  );
  if (latestUserMessage == null || latestUserMessage.text !== prompt) {
    return false;
  }
  return view.activeRequestIds.includes(latestUserMessage.requestId);
}

export function snapshotConfirmsPromptAccepted(
  snapshot: SessionSnapshot | null,
  target: { workspacePath: string; conversationId: string | null },
  prompt: string,
): boolean {
  if (snapshot == null) {
    return false;
  }

  const matchingViews = snapshot.conversationViews.filter((view) => {
    if (view.workspacePath !== target.workspacePath) {
      return false;
    }
    if (target.conversationId != null) {
      return view.conversationId === target.conversationId;
    }
    return (
      snapshot.activeWorkspacePath === target.workspacePath &&
      snapshot.activeConversationId === view.conversationId
    );
  });
  if (matchingViews.some((view) => viewLatestUserPromptLooksAccepted(view, prompt))) {
    return true;
  }

  if (target.conversationId != null) {
    return false;
  }

  if (
    snapshot.activeWorkspacePath !== target.workspacePath ||
    snapshot.activeConversationId == null
  ) {
    return false;
  }
  const latestVisibleUserMessage = snapshot.visibleMessages.findLast(
    (message) => message.kind === "user",
  );
  return (
    latestVisibleUserMessage != null &&
    latestVisibleUserMessage.text === prompt &&
    snapshot.visibleActiveRequestIds.includes(latestVisibleUserMessage.requestId)
  );
}
