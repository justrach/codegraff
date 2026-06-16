import type { ReactNode } from "react";

import {
  SettingsNavigationContext,
  type SettingsNavigationContextValue,
} from "./settingsNavigationContext";

export function SettingsNavigationProvider({
  children,
  value,
}: {
  children: ReactNode;
  value: SettingsNavigationContextValue;
}) {
  return (
    <SettingsNavigationContext.Provider value={value}>
      {children}
    </SettingsNavigationContext.Provider>
  );
}
