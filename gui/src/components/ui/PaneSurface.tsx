import type { CSSProperties } from "react";

import { cn } from "@/utils/cn";
import type { PaneSurfaceProps } from "./types/ui";

const embeddedPaneStyle: CSSProperties = {
  backgroundColor: "var(--pane-surface)",
};

const framedPaneStyle: CSSProperties = {
  ...embeddedPaneStyle,
  borderColor: "var(--pane-border)",
  boxShadow: "0 20px 45px -20px var(--pane-shadow)",
};

export function PaneSurface({
  children,
  className,
  framed = false,
  style,
  ...props
}: PaneSurfaceProps) {
  return (
    <section
      className={cn(
        "flex h-full min-h-0 min-w-0 flex-col overflow-hidden",
        framed ? "border" : null,
        className,
      )}
      style={{
        ...(framed ? framedPaneStyle : embeddedPaneStyle),
        ...style,
      }}
      {...props}
    >
      {children}
    </section>
  );
}
