import { createContext, useContext } from "react";

export interface SettingsNavigationContextValue {
  openProviderSettings: () => void;
  openMcpSettings: () => void;
}

export const SettingsNavigationContext =
  createContext<SettingsNavigationContextValue>({
    openProviderSettings: () => {},
    openMcpSettings: () => {},
  });

export function useSettingsNavigation() {
  return useContext(SettingsNavigationContext);
}
