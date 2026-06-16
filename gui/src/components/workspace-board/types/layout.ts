import type { ChatBinding } from "@/services/desktop/types/contracts";

export interface OuterChatPanelParams extends ChatBinding {
  title: string;
}

export interface PlaceholderPaneParams extends ChatBinding {
  kind: "preview" | "terminal";
  label: string;
}

export type TerminalPaneParams = PlaceholderPaneParams & {
  kind: "terminal";
};
