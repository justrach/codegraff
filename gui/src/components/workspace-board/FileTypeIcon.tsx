import { useMemo } from "react";
import { themeIcons } from "seti-icons";

import { cn } from "@/utils/cn";

// Seti file-type icons. Language hues stay vivid (Codex-style); neutral/default
// files follow the app theme tokens so they read on every preset + light/dark.
const getThemedIcon = themeIcons({
  blue: "#519aba",
  green: "#8dc149",
  orange: "#e37933",
  pink: "#f55385",
  purple: "#a074c4",
  red: "#cc3e44",
  yellow: "#cbcb41",
  grey: "var(--muted-foreground)",
  "grey-light": "var(--muted-foreground)",
  white: "var(--foreground)",
  ignore: "var(--faint)",
});

interface FileTypeIconProps {
  path: string;
  className?: string;
}

/**
 * Colored seti file-type icon for a path. The seti SVGs carry no `fill`, so we
 * tint them via `currentColor` (set through the resolved `color`).
 */
export function FileTypeIcon({ path, className }: FileTypeIconProps) {
  const fileName = path.split("/").pop() ?? path;
  const { svg, color } = useMemo(() => getThemedIcon(fileName), [fileName]);

  return (
    <span
      aria-hidden
      className={cn(
        "inline-flex shrink-0 items-center justify-center [&>svg]:size-[18px] [&>svg]:fill-current",
        className,
      )}
      style={{ color }}
      dangerouslySetInnerHTML={{ __html: svg }}
    />
  );
}
