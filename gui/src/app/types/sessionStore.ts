import type { StoreApi } from "zustand/vanilla";

import type {
  ConversationSessionSummary,
  ConversationViewSnapshot,
  PromptSettings,
  RuntimeStatus,
  SavedWorkspaceSummary,
  SessionSnapshot,
  WorkspaceSession,
} from "@/services/desktop/types/contracts";

import type { Attachment } from "@/components/attachments/attachmentTypes";

import type {
  RequestTimingInfo,
  WorkspaceBoardSelection,
} from "./sessionContext";

export interface PromptDraftEntry {
  isPending: boolean;
  isPlanningMode: boolean;
  /**
   * Per-turn opt-in to the harness `ultracode` codeword (multi-agent workflow
   * mode). The codeword is injected into the outgoing message text at submit,
   * then this flag is reset to false.
   */
  isUltraMode: boolean;
  value: string;
}

export interface WorkspaceMetaState {
  promptSettings: PromptSettings | null;
  promptSettingsLoaded: boolean;
  runtimeStatus: RuntimeStatus | null;
  runtimeStatusLoaded: boolean;
}

export interface SessionStoreState {
  activeConversationId: string | null;
  activeWorkspacePath: string | null;
  attachmentsByKey: Record<string, Attachment[]>;
  conversationSummariesByKey: Record<string, ConversationSessionSummary>;
  conversationViewsByKey: Record<string, ConversationViewSnapshot>;
  isBootstrapped: boolean;
  isOpeningProject: boolean;
  promptDraftsByKey: Record<string, PromptDraftEntry>;
  requestTimingsByConversationId: Record<
    string,
    Record<string, RequestTimingInfo>
  >;
  savedWorkspaces: SavedWorkspaceSummary[];
  selection: WorkspaceBoardSelection;
  uiError: string | null;
  workspaceMetaByKey: Record<string, WorkspaceMetaState>;
  workspaces: WorkspaceSession[];
  workspacesByPath: Record<string, WorkspaceSession>;
  applySessionSnapshot: (snapshot: SessionSnapshot) => void;
  addAttachments: (key: string | null, items: Attachment[]) => void;
  removeAttachment: (key: string | null, id: string) => void;
  clearAttachments: (key: string | null) => void;
  moveAttachments: (fromKey: string | null, toKey: string | null) => void;
  clearPromptDraft: (key: string | null) => void;
  movePromptDraft: (fromKey: string | null, toKey: string | null) => void;
  setBoardSelection: (selection: WorkspaceBoardSelection) => void;
  setIsBootstrapped: (value: boolean) => void;
  setIsOpeningProject: (value: boolean) => void;
  setPromptDraftPending: (key: string | null, isPending: boolean) => void;
  setPromptDraftPlanningMode: (
    key: string | null,
    isPlanningMode: boolean,
  ) => void;
  setPromptDraftUltraMode: (key: string | null, isUltraMode: boolean) => void;
  setPromptDraftValue: (key: string | null, value: string) => void;
  setWorkspacePromptSettings: (
    workspacePath: string | null,
    promptSettings: PromptSettings | null,
  ) => void;
  setWorkspaceRuntimeStatus: (
    workspacePath: string | null,
    runtimeStatus: RuntimeStatus | null,
  ) => void;
}

export type SessionStoreSetter = StoreApi<SessionStoreState>["setState"];
