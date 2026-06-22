import type { DragEvent as ReactDragEvent } from "react";
import type { SerializedDockview } from "dockview-react";

import type { ChatBinding } from "@/services/desktop/types/contracts";

export const SIDEBAR_CHAT_MIME = "application/x-codegraff-chat-binding";

export const OUTER_CHAT_COMPONENT = "chat-tile";
export const INNER_CHAT_COMPONENT = "conversation-pane";
export const INNER_PLACEHOLDER_COMPONENT = "placeholder-pane";

export const CHAT_PANE_ID = "chat";
export const PREVIEW_PANE_ID = "preview";
export const TERMINAL_PANE_ID = "terminal";
export const CHANGES_PANE_ID = "changes";
export const TERMINAL_RESTART_EVENT_NAME = "codegraff://terminal-restart-request";
export const PANE_CLOSE_REQUEST_EVENT_NAME = "codegraff://pane-close-request";

let activeDraggedChatBinding: ChatBinding | null = null;

export function areChatBindingsEqual(
  left: ChatBinding | null | undefined,
  right: ChatBinding | null | undefined,
): boolean {
  if (left == null || right == null) {
    return false;
  }

  return (
    left.workspacePath === right.workspacePath &&
    left.conversationId === right.conversationId
  );
}

export function createChatPanelId(binding: ChatBinding): string {
  return `chat:${encodeURIComponent(binding.workspacePath)}::${binding.conversationId}`;
}

export function createTerminalSessionId(
  binding: ChatBinding,
  terminalKey?: string,
): string {
  const base = `terminal:${encodeURIComponent(binding.workspacePath)}::${binding.conversationId}`;
  // Suffix the per-tab key so each terminal tab maps to its own PTY. Legacy panes
  // without a key fall back to "1" (matches the first tab's default key).
  return `${base}::${terminalKey ?? "1"}`;
}

// Dockview panel id for a terminal tab. The first/legacy terminal keeps the bare
// `TERMINAL_PANE_ID`; additional tabs are namespaced by their key.
export function createTerminalPanelId(terminalKey: string): string {
  return terminalKey === "1"
    ? TERMINAL_PANE_ID
    : `${TERMINAL_PANE_ID}:${terminalKey}`;
}

export function isTerminalPanelId(panelId: string): boolean {
  return panelId === TERMINAL_PANE_ID || panelId.startsWith(`${TERMINAL_PANE_ID}:`);
}

export function dispatchTerminalRestartRequest(terminalId: string): void {
  window.dispatchEvent(
    new CustomEvent(TERMINAL_RESTART_EVENT_NAME, {
      detail: { terminalId },
    }),
  );
}

/**
 * Request that an auxiliary pane close. The pane component listens for this so it
 * can play a slide-out animation before actually removing itself from the layout.
 */
export function dispatchPaneCloseRequest(paneId: string): void {
  window.dispatchEvent(
    new CustomEvent(PANE_CLOSE_REQUEST_EVENT_NAME, {
      detail: { paneId },
    }),
  );
}

export function parseDockviewLayoutJson(
  layoutJson: string | null | undefined,
): SerializedDockview | null {
  if (layoutJson == null || layoutJson.trim().length === 0) {
    return null;
  }

  try {
    return JSON.parse(layoutJson) as SerializedDockview;
  } catch {
    return null;
  }
}

export function extractBindingsFromSerializedLayout(
  layout: SerializedDockview | null | undefined,
): ChatBinding[] {
  if (layout == null) {
    return [];
  }

  const seen = new Set<string>();
  const bindings: ChatBinding[] = [];

  for (const panel of Object.values(layout.panels ?? {})) {
    const params = panel.params;
    if (
      params == null ||
      typeof params.workspacePath !== "string" ||
      typeof params.conversationId !== "string"
    ) {
      continue;
    }

    const binding = {
      workspacePath: params.workspacePath,
      conversationId: params.conversationId,
    } satisfies ChatBinding;
    const key = `${binding.workspacePath}::${binding.conversationId}`;
    if (seen.has(key)) {
      continue;
    }

    seen.add(key);
    bindings.push(binding);
  }

  return bindings;
}

export function extractBindingsFromLayoutJson(
  layoutJson: string | null | undefined,
): ChatBinding[] {
  return extractBindingsFromSerializedLayout(parseDockviewLayoutJson(layoutJson));
}

export function serializeDockviewLayout(layout: SerializedDockview): string {
  return JSON.stringify(layout);
}

export function writeChatBindingToDataTransfer(
  dataTransfer: DataTransfer | null,
  binding: ChatBinding,
): void {
  activeDraggedChatBinding = binding;

  if (dataTransfer == null) {
    return;
  }

  const payload = JSON.stringify(binding);
  dataTransfer.effectAllowed = "copyMove";
  dataTransfer.setData(SIDEBAR_CHAT_MIME, payload);
  dataTransfer.setData("text/plain", payload);
}

export function hasChatBindingDataTransfer(
  dataTransfer: DataTransfer | null,
): boolean {
  return (
    activeDraggedChatBinding != null ||
    dataTransferHasType(dataTransfer, SIDEBAR_CHAT_MIME)
  );
}

export function readChatBindingFromDataTransfer(
  dataTransfer: DataTransfer | null,
): ChatBinding | null {
  const payload = (
    dataTransfer?.getData(SIDEBAR_CHAT_MIME) ??
    dataTransfer?.getData("text/plain") ??
    ""
  ).trim();
  if (payload == null || payload.length === 0) {
    return activeDraggedChatBinding;
  }

  try {
    const value = JSON.parse(payload) as Partial<ChatBinding>;
    if (
      typeof value.workspacePath !== "string" ||
      typeof value.conversationId !== "string"
    ) {
      return null;
    }

    return {
      workspacePath: value.workspacePath,
      conversationId: value.conversationId,
    };
  } catch {
    return activeDraggedChatBinding;
  }
}

export function readChatBindingFromDragEvent(
  event: ReactDragEvent<HTMLElement> | DragEvent,
): ChatBinding | null {
  return readChatBindingFromDataTransfer(event.dataTransfer);
}

export function clearActiveDraggedChatBinding(): void {
  activeDraggedChatBinding = null;
}

function dataTransferHasType(
  dataTransfer: DataTransfer | null,
  type: string,
): boolean {
  const types = dataTransfer?.types;
  if (types == null) {
    return false;
  }

  if (Array.isArray(types)) {
    return types.includes(type);
  }

  if (
    "contains" in types &&
    typeof types.contains === "function"
  ) {
    return types.contains(type);
  }

  if ("includes" in types && typeof types.includes === "function") {
    return types.includes(type);
  }

  const length = "length" in types && typeof types.length === "number"
    ? types.length
    : 0;
  for (let index = 0; index < length; index += 1) {
    const value =
      "item" in types && typeof types.item === "function"
        ? types.item(index)
        : types[index];
    if (value === type) {
      return true;
    }
  }

  return false;
}
