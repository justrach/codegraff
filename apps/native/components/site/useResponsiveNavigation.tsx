import { useEffect, useId, useRef, useState } from "react";
import { IconSidebarLeftOpen } from "@/lib/icons";
import styles from "./ResponsiveNavigation.module.css";

/** Keep one sidebar mounted. Narrow windows reveal it in the native popover
 * layer, with light dismissal and Escape, instead of removing navigation. */
export function useResponsiveNavigation() {
  const id = useId(), panel = useRef<HTMLDivElement>(null);
  const [narrow, setNarrow] = useState(false), [open, setOpen] = useState(false);
  const close = () => { if (panel.current?.matches(":popover-open")) panel.current.hidePopover(); };
  useEffect(() => {
    const query = matchMedia("(width < 64rem)");
    const update = () => { if (!query.matches) close(); setNarrow(query.matches); };
    update(); query.addEventListener("change", update);
    return () => query.removeEventListener("change", update);
  }, []);
  return {
    close: narrow ? close : undefined,
    panelProps: {
      id, ref: panel, popover: narrow ? "auto" as const : undefined,
      className: styles.panel, "data-navigation-panel": true,
      role: narrow ? "dialog" : undefined, "aria-label": narrow ? "Navigation" : undefined,
      onToggle: (event: React.ToggleEvent<HTMLDivElement>) => {
        // React also delivers descendant popover toggles here. They own their
        // focus; opening an action menu must not refocus the sidebar close button.
        if (event.target !== event.currentTarget) return;
        const shown = event.newState === "open"; setOpen(shown);
        if (shown) panel.current?.querySelector<HTMLButtonElement>('[aria-label="Close navigation"]')?.focus();
      },
    },
    trigger: <button type="button" aria-label="Open navigation" title="Projects and conversations"
      aria-expanded={open} aria-controls={id} aria-haspopup="dialog" popoverTarget={id}
      className="flex size-7 shrink-0 items-center justify-center rounded-md text-ink-2 hover:bg-hover lg:hidden">
      <IconSidebarLeftOpen size={18} />
    </button>,
  };
}
