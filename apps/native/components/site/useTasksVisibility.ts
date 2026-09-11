"use client";

import { useEffect, useState } from "react";

const KEY = "graff.tasks.visible";

/** A view preference, not checklist state; survives panel and chat switches. */
export function useTasksVisibility() {
  const [open, setOpen] = useState(false);
  useEffect(() => {
    try { setOpen(localStorage.getItem(KEY) === "true"); } catch { /* optional storage */ }
  }, []);
  const change = (value: boolean) => {
    setOpen(value);
    try { localStorage.setItem(KEY, String(value)); } catch { /* optional storage */ }
  };
  return [open, change] as const;
}
