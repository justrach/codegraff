"use client";

import { useLayoutEffect, useRef, useState } from "react";
import { createPortal } from "react-dom";
import { IconCrossSmall } from "@/lib/icons";

/* ─────────────────────────────────────────────────────────
 * CLOSE CONFIRM DIALOG
 * Closing a tab stops its `graff acp` worker: the agent process is
 * retired and anything it was still running — background jobs,
 * subagents — stops with it. Worth confirming once, instead of
 * silently killing the chat under the user.
 * ───────────────────────────────────────────────────────── */

const BUTTON = "h-8 shrink-0 rounded-full px-3 text-[12.5px] font-medium transition-colors";

type Props = {
  /** Tabs about to close (a split tab closes its whole group). */
  tabs: number;
  /** How many of them own a live worker. The prompt only shows above zero. */
  workers: number;
  onCancel: () => void;
  onConfirm: (dontAskAgain: boolean) => void;
};

export default function CloseConfirmDialog({ tabs, workers, onCancel, onConfirm }: Props) {
  const panel = useRef<HTMLDivElement>(null);
  const confirm = useRef<HTMLButtonElement>(null);
  const [dontAskAgain, setDontAskAgain] = useState(false);
  const cancel = useRef(onCancel);
  cancel.current = onCancel;

  useLayoutEffect(() => {
    const dialog = panel.current!;
    const previous = document.activeElement as HTMLElement | null;
    // The portal is a direct body child. Inert background roots keep native
    // and programmatic focus out of the chat behind the modal.
    const background = Array.from(document.body.children)
      .filter((element): element is HTMLElement => element instanceof HTMLElement && !element.contains(dialog))
      .map((element) => ({ element, inert: element.inert }));
    background.forEach(({ element }) => { element.inert = true; });
    const controls = () => Array.from(dialog.querySelectorAll<HTMLElement>("button, input"))
      .filter((element) => !(element as HTMLButtonElement).disabled && element.getClientRects().length > 0);
    confirm.current?.focus({ preventScroll: true });
    const keepFocus = (event: FocusEvent) => {
      if (!dialog.contains(event.target as Node)) (controls()[0] ?? dialog).focus({ preventScroll: true });
    };
    const onKey = (event: KeyboardEvent) => {
      if (event.isComposing) return;
      if (event.key === "Escape") {
        event.preventDefault(); event.stopPropagation(); cancel.current();
        return;
      }
      if (event.key !== "Tab") return;
      const items = controls(), first = items[0], last = items.at(-1);
      if (!first || !last) return;
      if (!dialog.contains(document.activeElement) || (event.shiftKey ? document.activeElement === first : document.activeElement === last)) {
        event.preventDefault();
        (event.shiftKey ? last : first).focus({ preventScroll: true });
      }
    };
    document.addEventListener("keydown", onKey);
    document.addEventListener("focusin", keepFocus, true);
    return () => {
      document.removeEventListener("keydown", onKey);
      document.removeEventListener("focusin", keepFocus, true);
      background.forEach(({ element, inert }) => { element.inert = inert; });
      if (previous?.isConnected) previous.focus({ preventScroll: true });
    };
  }, []);

  const plural = tabs !== 1;
  const title = plural ? `Close ${tabs} tabs` : "Close tab";
  const stopLine = plural
    ? `Closing these tabs stops ${workers === tabs ? `their ${workers === 1 ? "agent" : "agents"}` : `${workers} running ${workers === 1 ? "agent" : "agents"}`}.`
    : "Closing this tab stops its agent.";

  return createPortal(
    <div
      className="fixed inset-0 z-[60] flex items-center justify-center p-4"
      style={{ background: "color-mix(in oklab, var(--ink) 22%, transparent)", animation: "fade-in 160ms ease both" }}
      onPointerDown={(event) => {
        if (event.target === event.currentTarget) onCancel();
      }}
    >
      <div
        ref={panel}
        role="dialog"
        tabIndex={-1}
        aria-modal="true"
        aria-label={title}
        className="flex w-full max-w-[440px] flex-col overflow-hidden rounded-window bg-surface shadow-overlay"
        style={{ animation: "pop-in 180ms cubic-bezier(0.23,1,0.32,1) both" }}
      >
        <div className="flex h-11 shrink-0 items-center gap-2 border-b border-line px-4">
          <span className="min-w-0 flex-1 truncate text-[13px] font-semibold text-ink">{title}</span>
          <button
            type="button"
            aria-label="Close"
            onClick={onCancel}
            className="flex size-7 items-center justify-center rounded-full text-ink-3 transition-colors duration-100 hover:bg-hover hover:text-ink"
          >
            <IconCrossSmall size={16} />
          </button>
        </div>

        <div className="flex flex-col gap-2 px-4 py-4 text-[12.5px] leading-5 text-ink-2">
          <p>{stopLine}</p>
          <p className="text-ink-3">Anything still running — background jobs, subagents — stops with {plural ? "them" : "it"}.</p>
          <label className="mt-1 flex cursor-pointer items-center gap-2 text-[12.5px] text-ink-2">
            <input type="checkbox" checked={dontAskAgain} onChange={(event) => setDontAskAgain(event.target.checked)} />
            Don&apos;t ask again
          </label>
        </div>

        <div className="flex shrink-0 items-center justify-end gap-2 border-t border-line px-4 py-3">
          <button type="button" onClick={onCancel} className={`${BUTTON} text-ink-2 hover:bg-hover hover:text-ink`}>
            Cancel
          </button>
          <button
            ref={confirm}
            type="button"
            onClick={() => onConfirm(dontAskAgain)}
            className={`${BUTTON} bg-ink px-3.5 text-canvas hover:opacity-90`}
          >
            {title}
          </button>
        </div>
      </div>
    </div>,
    document.body,
  );
}
