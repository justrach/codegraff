import { Archive } from "lucide-react";

import { cn } from "@/utils/cn";

import type { SidebarArchiveActionProps } from "./types/sidebar";
import { Button } from "./ui/Button";

export function SidebarArchiveAction({
  ariaLabel,
  className,
  disabled = false,
  onClick,
}: SidebarArchiveActionProps) {
  return (
    <Button
      type="button"
      variant="ghost"
      size="icon"
      className={cn(
        "absolute top-1/2 -translate-y-1/2 bg-black/0 opacity-0 hover:bg-black/0 focus-visible:opacity-100 dark:bg-white/0 dark:hover:bg-white/0 aria-expanded:bg-black/0 dark:aria-expanded:bg-white/0",
        className,
      )}
      aria-label={ariaLabel}
      title="Archive"
      disabled={disabled}
      onClick={(event) => {
        event.stopPropagation();
        onClick();
      }}
    >
      <Archive strokeWidth={2} className="size-3.5 shrink-0" />
    </Button>
  );
}
