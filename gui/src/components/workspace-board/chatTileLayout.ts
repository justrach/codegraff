import type {
  AddPanelPositionOptions,
  DockviewApi,
  DockviewGroupPanel,
  IDockviewPanel,
} from "dockview-react";

import type { ChatBinding } from "@/services/desktop/types/contracts";

import {
  CHANGES_PANE_ID,
  CHAT_PANE_ID,
  createTerminalPanelId,
  INNER_CHAT_COMPONENT,
  INNER_PLACEHOLDER_COMPONENT,
  isTerminalPanelId,
  PREVIEW_PANE_ID,
} from "./layout";
import type { PlaceholderPaneParams } from "./types/layout";

export function groupContainsChatPanel(
  group: DockviewGroupPanel | null | undefined,
): boolean {
  return group?.panels.some((panel) => panel.id === CHAT_PANE_ID) ?? false;
}

export function applyChatTileLayoutConstraints(api: DockviewApi): void {
  api.groups.forEach((group) => {
    group.locked = false;
    group.header.hidden = false;
  });
}

// Width (px) below which a side pane (preview/terminal/changes) auto-closes when
// the user drags it too small. Kept above dockview's enforced group minimum so the
// sash can actually reach the threshold.
const MIN_SIDE_PANE_WIDTH = 180;

/**
 * Close any auxiliary side pane that the user has dragged narrower than
 * {@link MIN_SIDE_PANE_WIDTH}. The chat pane is never auto-closed. Panes reporting
 * a width of 0 (not yet laid out) are skipped to avoid closing on mount.
 */
export function autoCloseUndersizedSidePanes(api: DockviewApi): void {
  for (const panel of api.panels) {
    if (panel.id === CHAT_PANE_ID) {
      continue;
    }
    const width = panel.api.width;
    if (width > 0 && width < MIN_SIDE_PANE_WIDTH) {
      panel.api.close();
    }
  }
}

export function buildDefaultChatTileLayout(
  api: DockviewApi,
  binding: ChatBinding,
): void {
  api.addPanel({
    id: CHAT_PANE_ID,
    component: INNER_CHAT_COMPONENT,
    tabComponent: INNER_CHAT_COMPONENT,
    title: "Chat",
    params: binding,
  });

  applyChatTileLayoutConstraints(api);
}

/** All open terminal tab panels in the chat tile, in layout order. */
export function getTerminalPanels(api: DockviewApi): IDockviewPanel[] {
  return api.panels.filter((panel) => isTerminalPanelId(panel.id));
}

let terminalKeyCounter = 0;

function generateTerminalKey(): string {
  terminalKeyCounter += 1;
  return `${Date.now().toString(36)}-${terminalKeyCounter}`;
}

/**
 * Add a terminal tab. The first terminal opens as a full-width pane below the grid
 * (spanning beneath chat + side panes) with the stable key "1"; subsequent ones are
 * added as sibling tabs in the same bottom group, each with its own PTY key.
 */
export function addTerminalTab(api: DockviewApi, binding: ChatBinding): void {
  if (api.getPanel(CHAT_PANE_ID) == null) {
    buildDefaultChatTileLayout(api, binding);
  }

  const existing = getTerminalPanels(api);
  const isFirst = existing.length === 0;
  const terminalKey = isFirst ? "1" : generateTerminalKey();
  const panelId = createTerminalPanelId(terminalKey);
  const title = isFirst ? "Terminal" : `Terminal ${existing.length + 1}`;
  const position: AddPanelPositionOptions = isFirst
    ? { direction: "below" }
    : { referencePanel: existing[existing.length - 1].id, direction: "within" };

  api.addPanel<PlaceholderPaneParams>({
    id: panelId,
    component: INNER_PLACEHOLDER_COMPONENT,
    tabComponent: INNER_PLACEHOLDER_COMPONENT,
    title,
    params: {
      ...binding,
      kind: "terminal",
      label: title,
      terminalKey,
    },
    // Keep every terminal tab mounted when inactive so switching tabs doesn't tear
    // down its PTY (dockview's default `onlyWhenVisible` would unmount it).
    renderer: "always",
    position,
  });

  applyChatTileLayoutConstraints(api);
}

export function openChatTilePane(
  api: DockviewApi,
  binding: ChatBinding,
  kind: PlaceholderPaneParams["kind"],
): void {
  if (kind === "terminal") {
    const existing = getTerminalPanels(api);
    if (existing.length > 0) {
      existing[existing.length - 1].focus();
      applyChatTileLayoutConstraints(api);
      return;
    }
    addTerminalTab(api, binding);
    return;
  }

  const panelId = kind === "preview" ? PREVIEW_PANE_ID : CHANGES_PANE_ID;
  const existingPanel = api.getPanel(panelId);
  if (existingPanel != null) {
    existingPanel.focus();
    applyChatTileLayoutConstraints(api);
    return;
  }

  const chatPanel = api.getPanel(CHAT_PANE_ID);
  if (chatPanel == null) {
    buildDefaultChatTileLayout(api, binding);
    openChatTilePane(api, binding, kind);
    return;
  }

  const panelTitle = kind === "preview" ? "Preview" : "Changes";
  // Preview/Changes open to the right of chat.
  api.addPanel<PlaceholderPaneParams>({
    id: panelId,
    component: INNER_PLACEHOLDER_COMPONENT,
    tabComponent: INNER_PLACEHOLDER_COMPONENT,
    title: panelTitle,
    params: {
      ...binding,
      kind,
      label: panelTitle,
    },
    position: { direction: "right", referencePanel: chatPanel },
  });

  applyChatTileLayoutConstraints(api);
}

export function shouldPreventChatOverlay(
  draggedPanel: IDockviewPanel | null,
  draggedGroup: DockviewGroupPanel | null,
  targetGroup: DockviewGroupPanel | null | undefined,
  position: string,
): boolean {
  return (
    position === "center" &&
    (
      draggedPanel?.id === CHAT_PANE_ID ||
      groupContainsChatPanel(draggedGroup) ||
      groupContainsChatPanel(targetGroup)
    )
  );
}

export function isSingleChatSelfDrop(
  draggedPanel: IDockviewPanel | null,
  draggedGroup: DockviewGroupPanel | null,
  targetGroup: DockviewGroupPanel | null | undefined,
): boolean {
  const isSameChatPanelGroupDrop =
    draggedPanel?.id === CHAT_PANE_ID &&
    targetGroup != null &&
    draggedPanel.group === targetGroup &&
    targetGroup.panels.length === 1;
  const isSameChatGroupDrop =
    draggedGroup != null &&
    groupContainsChatPanel(draggedGroup) &&
    targetGroup != null &&
    draggedGroup === targetGroup &&
    targetGroup.panels.length === 1;

  return isSameChatPanelGroupDrop || isSameChatGroupDrop;
}
