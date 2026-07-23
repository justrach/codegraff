import type {
  ChatBinding,
  SessionSnapshot,
  WorkspaceSession,
} from "../services/desktop/types/contracts";

export function snapshotHasConversationView(
  snapshot: SessionSnapshot,
  binding: ChatBinding,
) {
  return snapshot.conversationViews.some(
    (view) =>
      view.workspacePath === binding.workspacePath &&
      view.conversationId === binding.conversationId,
  );
}

export function findReusableManagedChatDraft(
  workspaces: WorkspaceSession[],
) {
  return (
    workspaces.find(
      (workspace) =>
        workspace.kind === "managed_chat" &&
        workspace.selectedConversationId == null &&
        workspace.conversations.length === 0,
    ) ?? null
  );
}

export async function runSnapshotCommand(
  command: () => Promise<SessionSnapshot>,
) {
  try {
    return await command();
  } catch {
    return null;
  }
}
