import type { ReactNode } from "react";

export type SettingsSection = "general" | "providers" | "mcp";

export interface AppSidebarControlProps {
  isFullscreen: boolean;
  isSidebarVisible: boolean;
  isSettingsViewOpen: boolean;
  onExitSettings: () => void;
}

export interface SessionProviderProps {
  children: ReactNode;
}
