"use client";
import { useEffect, useRef, useState } from "react";
import { desktop, type UpdateState } from "@/lib/desktop";

function statusCopy(state: UpdateState): string {
  return {
    idle: "Checks shortly after launch and every six hours.",
    checking: "Checking for updates…",
    current: `Codegraff ${state.currentVersion} is up to date.`,
    downloading: `Downloading Codegraff ${state.version} · ${state.percent ?? 0}%`,
    ready: `Codegraff ${state.version} is ready.`,
    installing: "Preparing to restart…",
    error: state.message ?? "Could not update.",
    unavailable: state.message ?? "Install a signed release in Applications to receive updates.",
  }[state.status];
}

export default function DesktopUpdates() {
  const [state, setState] = useState<UpdateState | null>(null);
  const [dismissed, setDismissed] = useState(false);
  const [open, setOpen] = useState(false);
  const previous = useRef<UpdateState["status"] | null>(null);
  const panel = useRef<HTMLDivElement>(null);
  useEffect(() => {
    const bridge = desktop();
    if (!bridge?.updates || !bridge.updateSubscribe) return;
    let alive = true;
    const receive = (next: UpdateState) => {
      if (!alive) return;
      if (next.status !== "downloading" || previous.current !== "downloading") setDismissed(false);
      previous.current = next.status;
      setState(next);
    };
    const unsubscribe = bridge.updateSubscribe(receive);
    void bridge.updates("state").then(receive).catch(() => {});
    return () => {
      alive = false;
      unsubscribe();
    };
  }, []);
  useEffect(() => {
    if (!open) return;
    const outside = (event: PointerEvent) => {
      if (!panel.current?.contains(event.target as Node)) setOpen(false);
    };
    const keys = (event: KeyboardEvent) => {
      if (event.key === "Escape") setOpen(false);
    };
    document.addEventListener("pointerdown", outside);
    document.addEventListener("keydown", keys);
    return () => {
      document.removeEventListener("pointerdown", outside);
      document.removeEventListener("keydown", keys);
    };
  }, [open]);
  if (!state) return null;

  const act = async (action: "check" | "restart" | "automatic", value?: boolean) => {
    try {
      const next = await desktop()?.updates?.(action, value);
      if (next) setState(next);
    } catch {
      setState({ ...state, status: "error", interactive: true, message: "Could not update. Please try again." });
    }
  };

  const toast =
    !dismissed &&
    state.status !== "idle" &&
    (state.interactive || !["current", "checking", "error", "unavailable"].includes(state.status));

  return (
    <>
      <div className="pointer-events-none fixed top-[calc(var(--desktop-title-height,0px)+10px)] right-3 z-[110]">
        <button
          type="button"
          data-desktop-update-settings
          aria-expanded={open}
          aria-haspopup="dialog"
          className="pointer-events-auto flex h-8 items-center gap-1.5 rounded-[8px] border border-line bg-page px-2.5 text-[12px] font-medium text-ink-2 shadow-hairline hover:bg-hover hover:text-ink"
          onClick={() => setOpen((value) => !value)}
        >
          Updates
        </button>
        {open && (
          <div
            ref={panel}
            role="dialog"
            aria-label="Update settings"
            data-desktop-update-panel
            className="pointer-events-auto absolute right-0 mt-2 w-80 max-w-[calc(100vw-24px)] rounded-xl border border-line bg-page p-3 text-sm text-ink shadow-card"
          >
            <p className="text-[11px] font-medium tracking-wide text-ink-3 uppercase">App updates</p>
            <p className="mt-1 text-[13px] text-ink">Codegraff {state.currentVersion}</p>
            <p role="status" className="mt-1 text-[12px] leading-relaxed text-ink-2">
              {statusCopy(state)}
            </p>
            {state.status === "downloading" && (
              <progress aria-label="Update download" max={100} value={state.percent ?? 0} className="mt-2 h-1 w-full accent-current" />
            )}
            <div className="mt-3 flex flex-col gap-2">
              <button
                type="button"
                data-desktop-update-check
                className="rounded-lg bg-hover px-3 py-1.5 text-left text-[12.5px] font-medium hover:bg-hover-2"
                onClick={() => void act("check")}
              >
                Check for Updates
              </button>
              {state.status === "ready" && (
                <button
                  type="button"
                  className="rounded-lg bg-ink px-3 py-1.5 text-left text-[12.5px] font-medium text-page"
                  onClick={() => void act("restart")}
                >
                  Restart to update
                </button>
              )}
              <button
                type="button"
                data-desktop-update-automatic
                role="switch"
                aria-checked={state.automatic}
                className="flex items-center justify-between rounded-lg px-1 py-1 text-[12.5px] text-ink-2 hover:bg-hover"
                onClick={() => void act("automatic", !state.automatic)}
              >
                <span>Download updates automatically</span>
                <span
                  aria-hidden
                  className={`ml-3 h-5 w-9 rounded-full p-0.5 transition-colors ${state.automatic ? "bg-accent" : "bg-hover-2"}`}
                >
                  <span className={`block size-4 rounded-full bg-page transition-transform ${state.automatic ? "translate-x-4" : ""}`} />
                </span>
              </button>
              <p className="px-1 text-[11px] leading-relaxed text-ink-3">
                When this is on, Codegraff checks shortly after launch and every six hours. Restart is always yours to confirm.
              </p>
            </div>
          </div>
        )}
      </div>
      {toast && (
        <div data-desktop-update className="fixed bottom-4 left-4 z-[110] w-80 max-w-[calc(100vw-32px)] rounded-xl border border-line bg-page p-3 text-sm text-ink shadow-card">
          <div className="flex items-center gap-3">
            <p role="status" className="min-w-0 flex-1">
              {statusCopy(state)}
            </p>
            <button aria-label="Dismiss update notification" className="size-7 shrink-0 rounded hover:bg-hover" onClick={() => setDismissed(true)}>
              ×
            </button>
          </div>
          {state.status === "downloading" && <progress aria-label="Update download" max={100} value={state.percent ?? 0} className="mt-2 h-1 w-full accent-current" />}
          {state.status === "ready" && (
            <>
              <p className="mt-1 text-xs text-ink-3">Restart when your work is finished. Active tasks and terminals will stop.</p>
              <button className="mt-2 rounded-lg bg-ink px-3 py-1.5 text-page" onClick={() => void act("restart")}>
                Restart to update
              </button>
            </>
          )}
          {state.status === "error" && (
            <button className="mt-2 rounded-lg bg-hover px-3 py-1.5" onClick={() => void act("check")}>
              Try again
            </button>
          )}
        </div>
      )}
    </>
  );
}
