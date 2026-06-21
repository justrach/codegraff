import type {
  ChatBinding,
  HandoffChatInput,
  SavedWorkspaceDetail,
  SessionSnapshot,
} from "@/services/desktop/types/contracts";

export interface RequestTimingInfo {
  completedAtMs: number | null;
  startedAtMs: number;
}

export interface SessionActionsContextValue {
  openWorkspacePicker: () => Promise<string | null>;
  openProject: (workspacePath: string) => Promise<void>;
  openSavedWorkspace: (workspaceId: string) => Promise<void>;
  selectConversation: (
    workspacePath: string,
    conversationId: string,
  ) => Promise<void>;
  archiveConversation: (
    workspacePath: string,
    conversationId: string,
  ) => Promise<void>;
  archiveWorkspace: (workspacePath: string) => Promise<void>;
  renameWorkspace: (
    workspacePath: string,
    displayName?: string | null,
  ) => Promise<void>;
  renameSavedWorkspace: (workspaceId: string, name: string) => Promise<void>;
  deleteSavedWorkspace: (workspaceId: string) => Promise<void>;
  startNewChat: (workspacePath?: string) => Promise<SessionSnapshot | null>;
  handoffChat: (input: HandoffChatInput) => Promise<SessionSnapshot | null>;
  checkoutBranch: (branchName: string) => Promise<void>;
  createBranch: (branchName: string) => Promise<void>;
  commitChanges: (message: string) => Promise<void>;
  pushBranch: () => Promise<void>;
  openInTarget: (targetId: string) => Promise<void>;
  updatePromptSettings: (input: {
    providerId: string;
    modelId: string;
    reasoningEffort?: string | null;
  }) => Promise<void>;
  stopPrompt: () => Promise<void>;
  submitPrompt: (draftOverride?: string) => Promise<void>;
  submitFollowup: (input: {
    cancelled: boolean;
    text?: string;
    selectedOptionIds?: string[];
  }) => Promise<void>;
}

export type WorkspaceBoardSelection =
  | { kind: "empty" }
  | { kind: "single-chat"; chat: ChatBinding }
  | { kind: "workspace-draft"; workspacePath: string }
  | {
      kind: "saved-workspace";
      workspace: SavedWorkspaceDetail;
      activeChat: ChatBinding | null;
    };
