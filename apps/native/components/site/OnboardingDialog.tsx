"use client";

import { useEffect, useRef } from "react";
import { createPortal } from "react-dom";
import { IconCrossSmall } from "@/lib/icons";
import { DESKTOP_SHORTCUTS } from "@/lib/desktop-shortcuts-help";
import type { AccountStatus } from "@/lib/account-client";

const BUTTON = "h-8 shrink-0 rounded-full px-3 text-[12.5px] font-medium transition-colors";

type Props = {
  account: AccountStatus;
  onClose: () => void;
  onLogin: () => void;
};

export default function OnboardingDialog({ account, onClose, onLogin }: Props) {
  const panel = useRef<HTMLDivElement>(null);
  const close = useRef(onClose);
  close.current = onClose;

  useEffect(() => {
    const dialog = panel.current;
    if (!dialog) return;
    const previous = document.activeElement as HTMLElement | null;
    dialog.querySelector<HTMLButtonElement>("button")?.focus({ preventScroll: true });
    const onKey = (event: KeyboardEvent) => {
      if (event.key === "Escape") { event.preventDefault(); event.stopPropagation(); close.current(); }
    };
    document.addEventListener("keydown", onKey);
    return () => {
      document.removeEventListener("keydown", onKey);
      if (previous?.isConnected) previous.focus({ preventScroll: true });
    };
  }, []);

  const sheet = (
    <div data-onboarding className="fixed inset-0 z-[65] flex items-center justify-center p-4">
      style={{ background: "color-mix(in oklab, var(--ink) 22%, transparent)" }}
      onPointerDown={event => { if (event.target === event.currentTarget) onClose(); }}>
      <div ref={panel} role="dialog" aria-modal="true" aria-label="Welcome to Codegraff"
        className="flex w-full max-w-[440px] flex-col overflow-hidden rounded-window bg-surface shadow-overlay">
        <div className="flex h-11 shrink-0 items-center gap-2 border-b border-line px-4">
          <span className="min-w-0 flex-1 truncate text-[13px] font-semibold text-ink">Welcome to Codegraff</span>
          <button type="button" aria-label="Close" onClick={onClose}
            className="flex size-7 items-center justify-center rounded-full text-ink-3 hover:bg-hover hover:text-ink">
            <IconCrossSmall size={16} />
          </button>
        </div>
        <div className="flex flex-col gap-4 px-4 py-4 text-[12.5px] leading-5 text-ink-2">
          <p>{account.signedIn
            ? "You are signed in. These shortcuts work in the desktop app."
            : "Sign in with Codegraff, then keep these shortcuts nearby."}</p>
          {!account.signedIn && <button type="button" onClick={onLogin}
            className="self-start rounded-full bg-accent px-3 py-2 text-[12.5px] font-medium text-white hover:bg-accent-ink">
            Login with Codegraff
          </button>}
          {account.signedIn && <p className="rounded-card bg-inset px-3 py-2 text-ink">Signed in · {account.plan ?? "Codegraff"}</p>}
          <ul className="m-0 list-none space-y-1.5 p-0">
            {DESKTOP_SHORTCUTS.map(row => (
              <li key={row.action} className="flex items-center justify-between gap-3 rounded-control px-1">
                <span>{row.action}</span>
                <kbd className="rounded-chip bg-hover px-1.5 py-0.5 font-mono text-[11px] text-ink">{row.keys}</kbd>
              </li>
            ))}
          </ul>
        </div>
        <div className="flex shrink-0 items-center justify-end gap-2 border-t border-line px-4 py-3">
          <button type="button" onClick={onClose} className={`${BUTTON} bg-ink px-3.5 text-canvas hover:opacity-90`}>
            {account.signedIn ? "Done" : "Skip for now"}
          </button>
        </div>
      </div>
    </div>
  );
  return typeof document === "undefined" ? sheet : createPortal(sheet, document.body);
}
