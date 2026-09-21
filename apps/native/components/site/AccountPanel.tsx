"use client";

import { useEffect, useRef } from "react";
import { createPortal } from "react-dom";
import { IconCrossSmall } from "@/lib/icons";
import type { AccountStatus } from "@/lib/account-client";

const ROW = "flex w-full items-center justify-start rounded-control px-3 py-2 text-left text-xs hover:bg-hover";

type Props = {
  account: AccountStatus;
  busy?: boolean;
  onClose: () => void;
  onLogin: () => void;
  onLogout: () => void;
  onSettings: () => void;
  onShortcuts: () => void;
};

export default function AccountPanel({ account, busy = false, onClose, onLogin, onLogout, onSettings, onShortcuts }: Props) {
  const panel = useRef<HTMLDivElement>(null);
  const close = useRef(onClose);
  close.current = onClose;

  useEffect(() => {
    const dialog = panel.current;
    if (!dialog) return;
    dialog.querySelector<HTMLButtonElement>("button")?.focus({ preventScroll: true });
    const onKey = (event: KeyboardEvent) => {
      if (event.key === "Escape") { event.preventDefault(); event.stopPropagation(); close.current(); }
    };
    const onPointer = (event: PointerEvent) => {
      if (!dialog.contains(event.target as Node)) close.current();
    };
    document.addEventListener("keydown", onKey);
    document.addEventListener("pointerdown", onPointer);
    return () => {
      document.removeEventListener("keydown", onKey);
      document.removeEventListener("pointerdown", onPointer);
    };
  }, []);

  const sheet = (
    <div className="fixed inset-0 z-[64] flex items-end justify-start p-3 sm:items-center sm:justify-center">
      <div ref={panel} data-account-panel role="dialog" aria-label="Account" aria-modal="true"
        className="flex w-full max-w-[320px] flex-col overflow-hidden rounded-window border border-line bg-surface p-1.5 shadow-overlay">
        <div className="flex items-start gap-2 px-3 py-2">
          <div className="min-w-0 flex-1">
            <p className="text-[13px] font-medium text-ink">{account.signedIn ? "Signed in" : "Not signed in"}</p>
            <p className="text-[12px] text-ink-3">{account.signedIn ? (account.plan ?? "Codegraff") : "Login with Codegraff to use the local agent."}</p>
          </div>
          <button type="button" aria-label="Close account" onClick={onClose}
            className="flex size-7 shrink-0 items-center justify-center rounded-full text-ink-3 hover:bg-hover hover:text-ink">
            <IconCrossSmall size={16} />
          </button>
        </div>
        {account.signedIn && <div className="mx-1.5 mb-1 rounded-card bg-inset px-3 py-2">
          <p className="text-[11px] font-medium uppercase tracking-wide text-ink-3">Plan / usage</p>
          <p className="mt-1 text-[12.5px] text-ink">{account.plan ?? "Codegraff"}</p>
          <p className="mt-1 text-[12px] text-ink-3">Session usage appears after a turn. Run /usage in chat for the current window.</p>
        </div>}
        {account.signedIn
          ? <button type="button" disabled={busy} onClick={onLogout} className={ROW}>Log out</button>
          : <button type="button" disabled={busy} onClick={onLogin} className={ROW}>Login with Codegraff</button>}
        <button type="button" onClick={onSettings} className={ROW}>Settings</button>
        <button type="button" onClick={onShortcuts} className={ROW}>Keyboard shortcuts</button>
      </div>
    </div>
  );
  return typeof document === "undefined" ? sheet : createPortal(sheet, document.body);
}
