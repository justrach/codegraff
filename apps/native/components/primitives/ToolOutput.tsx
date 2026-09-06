"use client";
import { useState } from "react";

/** Mount only on disclosure. Long output scrolls inside the call, never the page. */
export default function ToolOutput({ detail, mono }: { detail: { text: string; tone?: "add" }[]; mono?: boolean }) {
  const [copied, setCopied] = useState(false);
  const [error, setError] = useState(false);
  const text = detail.map(line => line.text).join("\n");
  return <div className="my-1 ml-2 min-w-0 border-l border-line pl-3.5">
    <button type="button" className="mb-1 text-xs text-ink-3 hover:text-ink" onClick={() => {
      void navigator.clipboard.writeText(text).then(() => { setCopied(true); setError(false); }).catch(() => setError(true));
    }}>{copied ? "Copied" : "Copy output"}</button>
    {error && <span role="alert" className="ml-2 text-xs text-red">Could not copy. Select the output to copy it.</span>}
    <div data-tool-output tabIndex={0} role="region" aria-label="Tool output" className="max-h-64 overflow-auto overscroll-contain rounded outline-offset-2">
      {detail.length ? detail.map((line, index) => <pre key={index} className={`whitespace-pre-wrap break-words [overflow-wrap:anywhere] text-[11.5px] leading-[1.6] ${mono ? "font-mono" : "font-sans"} ${line.tone === "add" ? "text-green" : "text-ink-2"}`}>{line.text}</pre>) : <p className="text-xs text-ink-3">No output received yet.</p>}
    </div>
  </div>;
}
