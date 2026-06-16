import { themeDark, themeLight } from "dockview-react";

import { useIsDarkTheme } from "@/hooks/useIsDarkTheme";

export function useDockviewTheme() {
  const isDarkTheme = useIsDarkTheme();
  return isDarkTheme ? themeDark : themeLight;
}
