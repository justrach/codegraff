import type { ChatBinding, SessionSnapshot } from "@/services/desktop/types/contracts";

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
