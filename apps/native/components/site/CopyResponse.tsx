"use client";
import { useEffect, useRef, useState } from "react";

/** Copy the response model, never the transcript DOM (which includes tools and thoughts). */
export default function CopyResponse({ text }: { text: string }) {
  const [state, setState] = useState<"idle" | "copied" | "error">("idle");
  const timer = useRef<ReturnType<typeof setTimeout> | undefined>(undefined);
  useEffect(() => () => clearTimeout(timer.current), []);
  const copy = async () => {
    clearTimeout(timer.current);
    try {
      await navigator.clipboard.writeText(text);
      setState("copied");
      timer.current = setTimeout(() => setState("idle"), 1500);
    } catch {
      setState("error");
    }
  };
  if (!text.trim()) return null;
  return <div className="mt-3 flex items-center gap-2">
    <button type="button" data-copy-response aria-label="Copy response" onClick={copy}
      className="flex h-7 items-center gap-1.5 rounded-full px-2 text-[12px] text-ink-3 transition-colors hover:bg-hover hover:text-ink focus-visible:outline-2 focus-visible:outline-accent">
      <svg width="13" height="13" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true">
        {state === "copied" ? <path d="m5 12 4 4L19 6" /> : <><rect x="8" y="8" width="12" height="12" rx="2" /><path d="M16 8V4a2 2 0 0 0-2-2H4a2 2 0 0 0-2 2v10a2 2 0 0 0 2 2h4" /></>}
      </svg>
      {state === "copied" ? "Copied" : "Copy response"}
    </button>
    <span role="status" className="text-[12px] text-ink-3">{state === "error" ? "Could not copy. Try again." : state === "copied" ? "Response copied" : ""}</span>
  </div>;
}
