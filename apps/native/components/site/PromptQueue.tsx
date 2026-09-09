"use client";

import type { QueuedPrompt } from "@/lib/prompt-queue";
import type { SteerStatus } from "@/lib/prompt-queue-steer";

export default function PromptQueue({ items, busy, status, error, onSteer, onRemove }: {
  items: QueuedPrompt[];
  busy: boolean;
  status?: SteerStatus;
  error?: string;
  onSteer: (id: number) => void;
  onRemove: (id: number) => void;
}) {
  const alert = error || status?.error;
  if (!items.length && !alert) return null;
  const pending = status?.pending !== undefined;
  return (
    <div className="mb-2">
      {alert && <p role="alert" className="mb-2 rounded-[8px] border border-line bg-surface px-2.5 py-2 text-[12px] text-ink">{alert}</p>}
      <ul aria-label="Queued messages" className="flex flex-col gap-1">
        {items.map(item => (
          <li key={item.id} className="flex flex-wrap items-center gap-2 rounded-[8px] bg-surface px-2.5 py-1.5 text-[12.5px] text-ink-2 shadow-hairline">
            <span className="shrink-0 text-[11px] font-medium tracking-wide text-ink-3 uppercase">Queued</span>
            <span className="min-w-0 flex-1 truncate text-ink" title={item.text}>{item.text}</span>
            <button type="button" disabled={!busy || pending} onClick={() => onSteer(item.id)}
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
          </li>
        ))}
      </ul>
      {pending && <p role="status" className="mt-1 text-[12px] text-ink-3">Interrupting the current turn. Selected message goes next; other messages stay queued.</p>}
    </div>
  );
}
