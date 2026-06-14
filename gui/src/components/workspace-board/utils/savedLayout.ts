import type { DockviewApi } from "dockview-react";

import {
  extractBindingsFromLayoutJson,
  parseDockviewLayoutJson,
} from "../layout";
import type {
  ApplySavedConversationLayoutResult,
  ApplySavedWorkspaceLayoutResult,
} from "../types/workspaceBoard";

export function applySavedWorkspaceLayout(
  api: DockviewApi,
  layoutJson: string,
): ApplySavedWorkspaceLayoutResult {
  const savedLayout = parseDockviewLayoutJson(layoutJson);
  const savedBindings = extractBindingsFromLayoutJson(layoutJson);

  if (savedLayout == null) {
    return { kind: "default", bindings: savedBindings };
  }

  try {
    api.fromJSON(savedLayout, { reuseExistingPanels: false });
    return { kind: "restored" };
  } catch {
    return { kind: "fallback", bindings: savedBindings };
  }
}

export function applySavedConversationLayout(
  api: DockviewApi,
  layoutJson: string | null,
): ApplySavedConversationLayoutResult {
  if (layoutJson == null) {
    return { kind: "default" };
  }

  const savedLayout = parseDockviewLayoutJson(layoutJson);
  if (savedLayout == null) {
    return { kind: "default" };
  }

  try {
    api.fromJSON(savedLayout, { reuseExistingPanels: false });
    return { kind: "restored" };
  } catch {
    return { kind: "fallback" };
  }
}
