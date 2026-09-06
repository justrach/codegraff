"use client";
import { useEffect, useRef, useState, type RefObject } from "react";

export default function ReviewActions({ diff, path, root, viewport, count }: {
  count: number; diff: string; path: string; root?: string; viewport: RefObject<HTMLElement | null>;
}) {
  const [hunk, setHunk] = useState(-1);
  const [copied, setCopied] = useState(false);
  const [error, setError] = useState("");
  const timer = useRef<ReturnType<typeof setTimeout> | undefined>(undefined);
  useEffect(() => { setHunk(-1); setCopied(false); setError(""); clearTimeout(timer.current); return () => clearTimeout(timer.current); }, [diff, path]);
  const jump = (direction: number) => {
    const nodes = viewport.current?.querySelectorAll<HTMLElement>("[data-diff-hunk]");
    if (!nodes?.length) return;
    const next = hunk < 0 ? (direction > 0 ? 0 : nodes.length - 1) : (hunk + direction + nodes.length) % nodes.length;
    nodes[next].scrollIntoView({ block: "start", behavior: "auto" }); setHunk(next);
  };
  const copy = async () => {
    try { await navigator.clipboard.writeText(diff); setError(""); setCopied(true); clearTimeout(timer.current); timer.current = setTimeout(() => setCopied(false), 1800); }
    catch { setError("Couldn't copy the diff. Try again."); }
  };
  const reveal = async () => {
    try {
      const reply = await fetch("/api/fs", { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ action: "reveal", path, root }) });
      if (!reply.ok) throw Error(); setError("");
    } catch { setError("Couldn't reveal this file in Finder."); }
  };
  const button = "rounded-[6px] px-2 py-1 text-[11px] text-ink-3 hover:bg-hover hover:text-ink focus-visible:outline-2 focus-visible:outline-accent disabled:opacity-30";
  return <footer className="shrink-0 border-t border-line bg-inset px-2 py-1.5">
    <div className="flex flex-wrap items-center gap-0.5">
      <button className={button} disabled={!count} aria-label="Previous changed section" onClick={() => jump(-1)}>↑</button>
      <span className="px-1 font-mono text-[10px] tabular-nums text-ink-3" aria-live="polite">{count ? `${hunk < 0 ? "–" : hunk + 1} / ${count} sections` : "No sections"}</span>
      <button className={button} disabled={!count} aria-label="Next changed section" onClick={() => jump(1)}>↓</button>
      <span className="flex-1" />
      <button className={button} disabled={!diff} onClick={() => void copy()}>{copied ? "Copied" : "Copy diff"}</button>
      <button className={button} disabled={!path} title="Reveal selected file in Finder" onClick={() => void reveal()}>Reveal</button>
    </div>
    {error && <p role="alert" className="px-2 py-1 text-xs text-red">{error}</p>}
  </footer>;
}
