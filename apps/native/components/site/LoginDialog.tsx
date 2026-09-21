"use client";

import { useEffect, useRef, useState } from "react";
import { createPortal } from "react-dom";
import { IconCrossSmall } from "@/lib/icons";
import { openVerification, pollLogin, startLogin, type DeviceStart } from "@/lib/account-client";

const BUTTON = "h-8 shrink-0 rounded-full px-3 text-[12.5px] font-medium transition-colors";

type Props = { onClose: () => void; onSignedIn: () => void };

export default function LoginDialog({ onClose, onSignedIn }: Props) {
  const panel = useRef<HTMLDivElement>(null);
  const [pending, setPending] = useState<DeviceStart | null>(null);
  const [error, setError] = useState("");
  const [busy, setBusy] = useState(false);
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

  useEffect(() => {
    if (!pending) return;
    let cancelled = false;
    let timer: ReturnType<typeof setTimeout> | undefined;
    const tick = async () => {
      try {
        const result = await pollLogin(pending.device_code);
        if (cancelled) return;
        if (result.status === "ok") { onSignedIn(); return; }
        if (result.status === "denied") { setError("Authorization denied."); return; }
        if (result.status === "expired") { setError("Code expired. Start again."); return; }
      } catch (cause) {
        if (!cancelled) setError(cause instanceof Error ? cause.message : String(cause));
        return;
      }
      timer = setTimeout(() => void tick(), pending.interval * 1000);
    };
    timer = setTimeout(() => void tick(), pending.interval * 1000);
    return () => { cancelled = true; if (timer) clearTimeout(timer); };
  }, [pending, onSignedIn]);

  const begin = async () => {
    setBusy(true); setError("");
    try {
      const start = await startLogin();
      setPending(start);
      openVerification(start.verification_uri_complete ?? start.verification_uri);
    } catch (cause) {
      setError(cause instanceof Error ? cause.message : String(cause));
    } finally {
      setBusy(false);
    }
  };

  const sheet = (
    <div className="fixed inset-0 z-[70] flex items-center justify-center p-4"
      style={{ background: "color-mix(in oklab, var(--ink) 22%, transparent)" }}
      onPointerDown={event => { if (event.target === event.currentTarget) onClose(); }}>
      <div ref={panel} role="dialog" aria-modal="true" aria-label="Login with Codegraff"
        className="flex w-full max-w-[420px] flex-col overflow-hidden rounded-window bg-surface shadow-overlay">
        <div className="flex h-11 shrink-0 items-center gap-2 border-b border-line px-4">
          <span className="min-w-0 flex-1 truncate text-[13px] font-semibold text-ink">Login with Codegraff</span>
          <button type="button" aria-label="Close" onClick={onClose}
            className="flex size-7 items-center justify-center rounded-full text-ink-3 hover:bg-hover hover:text-ink">
            <IconCrossSmall size={16} />
          </button>
        </div>
        <div className="flex flex-col gap-3 px-4 py-4 text-[12.5px] leading-5 text-ink-2">
          <p>Approve this device in the browser. The app stores the key where <span className="font-mono text-ink">graff login</span> already writes it, then restarts the local agent.</p>
          {pending ? <>
            <p>Open <span className="break-all font-mono text-ink">{pending.verification_uri}</span> and enter:</p>
            <p data-login-code className="rounded-card bg-inset px-3 py-2 text-center font-mono text-[20px] tracking-[0.2em] text-ink">{pending.user_code || "••••"}</p>
            <p className="text-ink-3">Waiting for approval…</p>
          </> : <p>Same-machine login only. A remote agent host still needs a terminal login.</p>}
          {error && <p role="alert" className="text-red">{error}</p>}
        </div>
        <div className="flex shrink-0 items-center justify-end gap-2 border-t border-line px-4 py-3">
          <button type="button" onClick={onClose} className={`${BUTTON} text-ink-2 hover:bg-hover hover:text-ink`}>Cancel</button>
          <button type="button" disabled={busy || !!pending} onClick={() => void begin()}
            className={`${BUTTON} bg-accent px-3.5 text-white hover:bg-accent-ink disabled:opacity-50`}>
            {pending ? "Waiting…" : "Login with Codegraff"}
          </button>
        </div>
      </div>
    </div>
  );
  return typeof document === "undefined" ? sheet : createPortal(sheet, document.body);
}
