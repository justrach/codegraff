"use client";
import { useEffect } from "react";
import { appearanceEvent, appearanceKey, customThemeKey, applyAppearance, readAppearance } from "@/lib/appearance";

export function ThemeSync() {
  useEffect(() => {
    const sync = () => applyAppearance(readAppearance());
    const storage = (event: StorageEvent) => { if (event.key === appearanceKey || event.key === customThemeKey || event.key === null) sync(); };
    sync(); window.addEventListener(appearanceEvent, sync); window.addEventListener("storage", storage);
    return () => { window.removeEventListener(appearanceEvent, sync); window.removeEventListener("storage", storage); };
  }, []);
  return null;
}
