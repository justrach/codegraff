"use client";

import { useLayoutEffect, useRef } from "react";
import { createPortal } from "react-dom";
import { IconCrossSmall } from "@/lib/icons";

/* ─────────────────────────────────────────────────────────
 * MODEL SWITCH DIALOG
 * The composer's picker cannot swap a model inside a live agent: it
 * respawns `graff acp --model <new> --resume <session>`, so the tab goes
 * quiet for a moment while the old worker is retired and the conversation
 * is reloaded onto the new model. Anything the outgoing agent was still
 * running — background jobs, subagents — stops with it. That is worth
 * confirming once, instead of silently restarting the chat under the user.
 * ───────────────────────────────────────────────────────── */

const BUTTON = "h-8 shrink-0 rounded-full px-3 text-[12.5px] font-medium transition-colors";

type Props = {
  /** The model being left, as the composer showed it. */
  from: string;
  /** The model being switched to. */
  to: string;
  onCancel: () => void;
  onConfirm: () => void;
};

export default function ModelSwitchDialog({ from, to, onCancel, onConfirm }: Props) {
  const panel = useRef<HTMLDivElement>(null);
  const confirm = useRef<HTMLButtonElement>(null);
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
    const controls = () => Array.from(dialog.querySelectorAll<HTMLButtonElement>("button"))
      .filter((element) => !element.disabled && element.getClientRects().length > 0);
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

  return createPortal(
    <div
      className="fixed inset-0 z-[300] flex items-center justify-center p-4"
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
        aria-label={`Switch model to ${to}`}
        className="flex w-full max-w-[440px] flex-col overflow-hidden rounded-window bg-surface shadow-overlay"
        style={{ animation: "pop-in 180ms cubic-bezier(0.23,1,0.32,1) both" }}
      >
        <div className="flex h-11 shrink-0 items-center gap-2 border-b border-line px-4">
          <span className="min-w-0 flex-1 truncate text-[13px] font-semibold text-ink">Switch model</span>
          <button
            type="button"
            aria-label="Close"
            onClick={onCancel}
            className="flex size-7 items-center justify-center rounded-[6px] text-ink-3 transition-colors duration-100 hover:bg-hover hover:text-ink"
          >
            <IconCrossSmall size={16} />
          </button>
        </div>

        <div className="flex flex-col gap-2 px-4 py-4 text-[12.5px] leading-5 text-ink-2">
          <p>
            This chat restarts its agent on <span className="font-medium text-ink">{to}</span>
            {from !== to && <> instead of <span className="font-medium text-ink">{from}</span></>}.
          </p>
          <p>The conversation is reloaded onto the new model, so its history carries over.</p>
          <p className="text-ink-3">Anything the current agent is still running — background jobs, subagents — stops.</p>
        </div>

        <div className="flex shrink-0 items-center justify-end gap-2 border-t border-line px-4 py-3">
          <button type="button" onClick={onCancel} className={`${BUTTON} text-ink-2 hover:bg-hover hover:text-ink`}>
            Cancel
          </button>
          <button
            ref={confirm}
            type="button"
            onClick={onConfirm}
            className={`${BUTTON} bg-ink px-3.5 text-canvas hover:opacity-90`}
          >
            Switch model
          </button>
        </div>
      </div>
    </div>,
    document.body,
  );
}
