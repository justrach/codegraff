"use client";
import { useEffect, useState } from "react";

export function commandGlyph(platform = typeof navigator === "undefined" ? "" : navigator.platform): string {
  return /Mac|iPhone|iPad/.test(platform) ? "⌘" : "Ctrl+";
}

export function shortcutModifiers(event: Pick<KeyboardEvent, "metaKey" | "ctrlKey" | "altKey">, platform: string) {
  const mac = /Mac|iPhone|iPad/.test(platform);
  return { command: mac ? event.metaKey : event.ctrlKey,
    resize: mac ? event.metaKey && event.ctrlKey : event.ctrlKey && event.altKey };
}

export function isFullscreenShortcut(event: Pick<KeyboardEvent, "key" | "metaKey" | "ctrlKey" | "altKey" | "shiftKey">, platform: string): boolean {
  if (event.altKey || event.shiftKey || !shortcutModifiers(event, platform).command) return false;
  return event.key.toLowerCase() === "enter" ||
    (/Mac|iPhone|iPad/.test(platform) && event.metaKey && event.ctrlKey && event.key.toLowerCase() === "f");
}

export function useCommandGlyph(): string {
  const [glyph, setGlyph] = useState("⌘");
  useEffect(() => { setGlyph(commandGlyph()); }, []);
  return glyph;
}
