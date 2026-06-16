import type {
  ConversationSessionSummary,
  SessionSnapshot,
  WorkspaceSession,
} from '../services/desktop/types/contracts'

export const LATEST_WORKSPACE_STORAGE_KEY = 'session:latest-workspace-path'

function getConversationDraftKey(conversationId: string): string {
  return `conversation:${conversationId}`
}

export function getWorkspaceDraftKey(workspacePath: string): string {
  return `workspace:${workspacePath}`
}

export function getPromptDraftKey(
  workspacePath: string | null | undefined,
  conversationId: string | null | undefined,
): string | null {
  if (conversationId != null) {
    return getConversationDraftKey(conversationId)
  }

  if (workspacePath != null) {
    return getWorkspaceDraftKey(workspacePath)
  }

  return null
}

export function getActiveWorkspace(
  snapshot: SessionSnapshot | null,
): WorkspaceSession | null {
  if (snapshot == null || snapshot.activeWorkspacePath == null) {
    return null
  }

  return (
    snapshot.workspaces.find(
      (workspace) => workspace.workspacePath === snapshot.activeWorkspacePath,
    ) ?? null
  )
}

export function getActiveWorkspaceLabel(snapshot: SessionSnapshot | null): string {
  return getActiveWorkspace(snapshot)?.workspaceName ?? 'Projects'
}

export function getActiveConversation(
  snapshot: SessionSnapshot | null,
): ConversationSessionSummary | null {
  const activeWorkspace = getActiveWorkspace(snapshot)
  if (activeWorkspace == null || snapshot?.activeConversationId == null) {
    return null
  }

  return (
    activeWorkspace.conversations.find(
      (conversation) => conversation.conversationId === snapshot.activeConversationId,
    ) ?? null
  )
}

export function resolveLatestWorkspacePath(
  snapshot: SessionSnapshot,
  storedWorkspacePath: string | null,
): string | null {
  if (storedWorkspacePath != null) {
    const matchingWorkspace = snapshot.workspaces.find(
      (workspace) => workspace.workspacePath === storedWorkspacePath,
    )
    if (matchingWorkspace != null) {
      return matchingWorkspace.workspacePath
    }
  }

  return snapshot.workspaces[0]?.workspacePath ?? null
}
