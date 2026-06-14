import type { ChatBinding } from "@/services/desktop/types/contracts";

export interface UseDockviewLayoutPersistenceOptions {
  delayMs?: number;
  onPersist: (layoutJson: string) => Promise<void>;
}

export type ApplySavedWorkspaceLayoutResult =
  | { kind: "restored" }
  | { kind: "default"; bindings: ChatBinding[] }
  | { kind: "fallback"; bindings: ChatBinding[] };

export type ApplySavedConversationLayoutResult =
  | { kind: "restored" }
  | { kind: "default" }
  | { kind: "fallback" };

export interface ChatTileProps {
  binding: ChatBinding;
  canCloseChat: () => boolean;
  onCloseChat: () => void;
}

export type TerminalStatus =
  | { kind: "connecting"; message: string }
  | { kind: "exited"; message: string }
  | { kind: "error"; message: string }
  | null;

export interface TerminalGridSize {
  cols: number;
  rows: number;
}
