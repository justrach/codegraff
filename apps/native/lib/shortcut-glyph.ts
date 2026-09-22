"use client";
import { useEffect, useState } from "react";

export function commandGlyph(platform = typeof navigator === "undefined" ? "" : navigator.platform): string {
  return /Mac|iPhone|iPad/.test(platform) ? "⌘" : "Ctrl+";
}

export function useCommandGlyph(): string {
  const [glyph, setGlyph] = useState("⌘");
  useEffect(() => { setGlyph(commandGlyph()); }, []);
  return glyph;
}
