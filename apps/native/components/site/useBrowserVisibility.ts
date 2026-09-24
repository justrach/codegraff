"use client";
import { useEffect, useRef, useState } from "react";
import { desktop } from "@/lib/desktop";
export function useBrowserVisibility(onAgentOpen: (chat?: string) => string | false) {
  const [open, setOpen] = useState(false);
  const callback = useRef(onAgentOpen); callback.current = onAgentOpen;
  useEffect(() => desktop()?.subscribe(event => {
    if (event.type === "show" && event.chat) { if (callback.current(event.chat)) setOpen(true); }
    if (event.type === "open-link" && event.url) {
      const chat = callback.current();
      if (chat) {
        setOpen(true);
        // Electron already validated the link; navigation remains in the isolated side pane.
        void desktop()?.browser(chat, "navigate", { url: event.url }).catch(() => {});
      }
    }
  }), []);
  return [open, setOpen] as const;
}
