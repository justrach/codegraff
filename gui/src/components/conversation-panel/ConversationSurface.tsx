import { PaneSurface } from "@/components/ui/PaneSurface";
import { cn } from "@/utils/cn";
import type { ConversationSurfaceProps } from "./types/conversationHeader";

export function ConversationSurface({
  children,
  className,
  ...props
}: ConversationSurfaceProps) {
  return (
    <PaneSurface
      className={cn(
        "flex-1 shadow-xl shadow-foreground/5 dark:shadow-black/20",
        className,
      )}
      framed
      {...props}
    >
      {children}
    </PaneSurface>
  );
}
