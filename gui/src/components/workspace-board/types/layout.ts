import type { ChatBinding } from "@/services/desktop/types/contracts";

export interface OuterChatPanelParams extends ChatBinding {
  title: string;
}

export interface PlaceholderPaneParams extends ChatBinding {
  kind: "preview" | "terminal" | "changes";
  label: string;
  // Per-tab key for terminal panes so multiple terminals each get a distinct PTY
  // (persisted in the layout so sessions are stable across restore).
  terminalKey?: string;
}

export type TerminalPaneParams = PlaceholderPaneParams & {
  kind: "terminal";
  terminalKey?: string;
};
