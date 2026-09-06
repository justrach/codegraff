"use client";
import { useEffect, useRef, useState } from "react";
import { desktop } from "@/lib/desktop";
export function useBrowserVisibility(key: string, onAgentOpen: (chat: string) => boolean) {
  const [open, setOpen] = useState(false);
  const restored = useRef(false);
  const callback = useRef(onAgentOpen); callback.current = onAgentOpen;
  useEffect(() => {
    try {
      if (!restored.current) { restored.current = true; setOpen(localStorage.getItem(key) !== "0"); }
      else localStorage.setItem(key, open ? "1" : "0");
    } catch {}
  }, [key, open]);
  useEffect(() => desktop()?.subscribe(event => {
    if (event.type === "show" && event.chat) { if (callback.current(event.chat)) setOpen(true); }
  }), []);
  return [open, setOpen] as const;
}
