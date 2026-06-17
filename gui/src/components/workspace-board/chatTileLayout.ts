import type {
  DockviewApi,
  DockviewGroupPanel,
  IDockviewPanel,
} from "dockview-react";

import type { ChatBinding } from "@/services/desktop/types/contracts";

import {
  CHANGES_PANE_ID,
  CHAT_PANE_ID,
  INNER_CHAT_COMPONENT,
  INNER_PLACEHOLDER_COMPONENT,
  PREVIEW_PANE_ID,
  TERMINAL_PANE_ID,
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

export function openChatTilePane(
  api: DockviewApi,
  binding: ChatBinding,
  kind: PlaceholderPaneParams["kind"],
): void {
  const panelId =
    kind === "preview"
      ? PREVIEW_PANE_ID
      : kind === "changes"
        ? CHANGES_PANE_ID
        : TERMINAL_PANE_ID;
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

  const previewPanel = api.getPanel(PREVIEW_PANE_ID);
  const panelTitle =
    kind === "preview" ? "Preview" : kind === "changes" ? "Changes" : "Terminal";
  // Preview/Changes open to the right of chat; terminal stacks below the preview.
  const referencePanel =
    kind === "terminal" && previewPanel != null ? previewPanel : chatPanel;
  const direction =
    kind === "terminal" ? (previewPanel != null ? "below" : "right") : "right";

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
    position: {
      direction,
      referencePanel,
    },
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
