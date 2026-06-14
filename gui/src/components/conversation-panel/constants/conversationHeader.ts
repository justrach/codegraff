import {
  BotIcon,
  FolderIcon,
  GhostIcon,
  HammerIcon,
  SmartphoneIcon,
  SquareTerminalIcon,
  TerminalIcon,
} from "lucide-react";

import type { AppTarget, AppTargetId } from "../types/conversationHeader";

export const appTargets: readonly AppTarget[] = [
  { id: "cursor", label: "Cursor", icon: BotIcon },
  { id: "zed", label: "Zed", icon: SquareTerminalIcon },
  { id: "file-manager", label: "Finder", icon: FolderIcon },
  { id: "terminal", label: "Terminal", icon: TerminalIcon },
  { id: "ghostty", label: "Ghostty", icon: GhostIcon },
  { id: "warp", label: "Warp", icon: SquareTerminalIcon },
  { id: "xcode", label: "Xcode", icon: HammerIcon },
  { id: "android-studio", label: "Android Studio", icon: SmartphoneIcon },
];

export const DEFAULT_APP_TARGET_ID: AppTargetId = appTargets[0].id;
export const OPEN_IN_PREFERRED_APP_STORAGE_KEY = "codegraff:preferred-open-app";
export const EDITOR_APP_TARGET_IDS: readonly AppTargetId[] = [
  "cursor",
  "zed",
  "xcode",
  "android-studio",
];
export const NO_PROJECT_VALUE = "__no_project__";
