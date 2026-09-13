"use client";

import { useEffect, useRef, useState } from "react";
import { markerName, splitImageMarkers } from "@/lib/attachments";
import type { QueuedPrompt } from "@/lib/prompt-queue";
import type { SteerStatus } from "@/lib/prompt-queue-steer";

/** The pixels behind a queued `@[…]` marker, from the staged file `/api/attach`
 *  serves back — the same image the sent bubble shows, sized for the row, and
 *  named like the composer's own chip so the file is never ambiguous. */
function QueuedImage({ name }: { name: string }) {
  const [failed, setFailed] = useState(false);
  const src = `/api/attach?name=${encodeURIComponent(name)}`;
  return (
    <a href={src} target="_blank" rel="noreferrer" title={`Open ${name}`}
      className="flex shrink-0 items-center gap-1 rounded-[5px] bg-field py-0.5 pr-1.5 pl-0.5 text-[11.5px] text-ink-2">
      {!failed && (
        /* Local staged pixels: no remote image optimizer or expiring object URL. */
        /* eslint-disable-next-line @next/next/no-img-element */
        <img src={src} alt="" loading="lazy" onError={() => setFailed(true)} className="size-5 rounded-[4px] object-cover" />
      )}
      <span className="max-w-28 truncate">{name}</span>
    </a>
  );
}

export default function PromptQueue({ items, busy, status, error, onSteer, onRemove, onEdit, onBeginEdit, onCancelEdit, onChangeEdit }: {
  items: QueuedPrompt[];
  busy: boolean;
  status?: SteerStatus;
  error?: string;
  onSteer: (id: number) => void;
  onRemove: (id: number) => void;
  onEdit: (id: number, text: string) => void;
  onBeginEdit: (id: number) => void;
  onCancelEdit: (id: number) => void;
  onChangeEdit: (id: number, draft: string) => void;
}) {
  // The queue owns drafts, so switching tabs or zooming panes cannot discard
  // an edit or release its hold. Only explicit actions change queue state.
  const editor = items.find(item => item.editing);
  const editing = editor?.id;
  const draft = editor?.draft ?? "";
  const inputRef = useRef<HTMLTextAreaElement>(null);
  useEffect(() => {
    // Opening the editor hands the caret the row's own text, ready to replace.
    if (editing !== undefined) { inputRef.current?.focus(); inputRef.current?.select(); }
  }, [editing]);
  const alert = error || status?.error;
  if (!items.length && !alert) return null;
  const pending = status?.pending !== undefined;
  const commit = (id: number) => onEdit(id, draft);
  return (
    <div className="mb-2">
      {alert && <p role="alert" className="mb-2 rounded-[8px] border border-line bg-surface px-2.5 py-2 text-[12px] text-ink">{alert}</p>}
      <ul aria-label="Queued messages" className="flex flex-col gap-1">
        {items.map(item => {
          const parts = splitImageMarkers(item.text);
          const held = status?.pending === item.id;
          // The words without their markers; a marker never renders as a path.
          const label = parts.filter((_, index) => index % 2 === 0).join("").replace(/\s+/g, " ").trim();
          return (
          <li key={item.id} data-queued-prompt={item.id} className="flex flex-wrap items-center gap-2 rounded-[8px] bg-surface px-2.5 py-1.5 text-[12.5px] text-ink-2 shadow-hairline">
            <span className="shrink-0 text-[11px] font-medium tracking-wide text-ink-3 uppercase">Queued</span>
            {editing === item.id ? (
              <>
                <textarea
                  ref={inputRef}
                  aria-label="Edit queued message"
                  rows={2}
                  value={draft}
                  onChange={(event) => onChangeEdit(item.id, event.target.value)}
                  onKeyDown={(event) => {
                    if (event.key === "Enter" && !event.shiftKey && !event.nativeEvent.isComposing) { event.preventDefault(); commit(item.id); }
                    if (event.key === "Escape") { event.preventDefault(); onCancelEdit(item.id); }
                  }}
                  className="min-w-0 flex-1 rounded-[6px] bg-field px-1.5 py-0.5 text-[12.5px] text-ink outline-none"
                />
                <button type="button" onClick={() => commit(item.id)} title="Save the edit (Enter)" aria-label="Save queued message"
                  className="flex size-5 shrink-0 items-center justify-center rounded-[5px] text-ink-2 hover:bg-hover hover:text-ink">
                  <svg width="11" height="11" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2.6" strokeLinecap="round" strokeLinejoin="round" aria-hidden>
                    <path d="M20 6L9 17l-5-5" />
                  </svg>
                </button>
                <button type="button" onClick={() => onCancelEdit(item.id)} title="Cancel the edit (Esc)" aria-label="Cancel edit"
                  className="flex size-5 shrink-0 items-center justify-center rounded-[5px] text-ink-3 hover:bg-hover hover:text-ink">
                  <svg width="10" height="10" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2.4" strokeLinecap="round" aria-hidden>
                    <path d="M18 6L6 18M6 6l12 12" />
                  </svg>
                </button>
              </>
            ) : (
              <>
                <span className="min-w-0 flex-1 truncate text-ink" title={item.text}>{label || "Attachment only"}</span>
                {parts.map((part, index) => index % 2 === 1
                  ? <QueuedImage key={`${index}-${part}`} name={markerName(part)} />
                  : null)}
                <button type="button" aria-label="Edit queued message" title="Edit before it is sent" disabled={held || editing !== undefined}
                  onClick={() => onBeginEdit(item.id)}
                  className="flex size-5 shrink-0 items-center justify-center rounded-[5px] text-ink-3 hover:bg-hover hover:text-ink disabled:opacity-50">
                  <svg width="10" height="10" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" aria-hidden>
                    <path d="M4 20h4L19 9a2.8 2.8 0 0 0-4-4L4 16v4Z" />
                  </svg>
                </button>
                <button type="button" disabled={!busy || pending || editing !== undefined} onClick={() => onSteer(item.id)}
                  title="Interrupt the current turn and send this message next"
                  className="shrink-0 rounded px-1.5 py-0.5 text-[11.5px] font-medium text-ink-2 hover:bg-hover hover:text-ink disabled:opacity-50">
                  {status?.pending === item.id ? "Steering…" : "Steer now"}
                </button>
                <button type="button" aria-label="Remove from queue" disabled={status?.pending === item.id} onClick={() => onRemove(item.id)}
                  className="flex size-5 shrink-0 items-center justify-center rounded-[5px] text-ink-3 hover:bg-hover hover:text-ink disabled:opacity-50">
                  <svg width="10" height="10" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2.4" strokeLinecap="round" aria-hidden>
                    <path d="M18 6L6 18M6 6l12 12" />
                  </svg>
                </button>
              </>
            )}
          </li>
          );
        })}
      </ul>
      {items.some(item => item.editing) && <p role="status" className="mt-1 text-[12px] text-ink-3">Messages stay queued until you save or cancel the edit.</p>}
      {pending && <p role="status" className="mt-1 text-[12px] text-ink-3">Interrupting the current turn. Selected message goes next; other messages stay queued.</p>}
    </div>
  );
}
