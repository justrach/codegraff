import { createContext, useContext } from "react";

// Whether the desktop sidebar is currently expanded. When it is collapsed, the
// active full-window panel sits under the macOS traffic lights and must reserve
// the titlebar inset.
export const SidebarVisibilityContext = createContext<boolean>(true);

export function useSidebarVisible(): boolean {
  return useContext(SidebarVisibilityContext);
}
