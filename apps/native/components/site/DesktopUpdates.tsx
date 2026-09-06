"use client";
import { useEffect, useRef, useState } from "react";
import { desktop, type UpdateState } from "@/lib/desktop";

export default function DesktopUpdates() {
  const [state, setState] = useState<UpdateState | null>(null);
  const [dismissed, setDismissed] = useState(false);
  const previous = useRef<UpdateState['status'] | null>(null);
  useEffect(() => {
    const bridge = desktop();
    if (!bridge?.updates || !bridge.updateSubscribe) return;
    let alive = true;
    const receive = (next: UpdateState) => {
      if (!alive) return;
      if (next.status !== 'downloading' || previous.current !== 'downloading') setDismissed(false);
      previous.current = next.status;
      setState(next);
    };
    const unsubscribe = bridge.updateSubscribe(receive);
    void bridge.updates('state').then(receive).catch(() => {});
    return () => { alive = false; unsubscribe(); };
  }, []);
  if (!state || dismissed || state.status === 'idle' || (!state.interactive && ['current', 'checking', 'error', 'unavailable'].includes(state.status))) return null;
  const message = {
    checking: 'Checking for updates…', current: `Codegraff ${state.currentVersion} is up to date.`,
    downloading: `Downloading Codegraff ${state.version} · ${state.percent ?? 0}%`,
    ready: `Codegraff ${state.version} is ready.`, installing: 'Preparing to restart…',
    error: state.message, unavailable: state.message,
  }[state.status];
  const act = async (action: 'check' | 'restart') => {
    try { const next = await desktop()?.updates?.(action); if (next) setState(next); }
    catch { setState({ ...state, status: 'error', interactive: true, message: 'Could not update. Please try again.' }); }
  };
  return <div data-desktop-update className="fixed bottom-4 left-4 z-[110] w-80 max-w-[calc(100vw-32px)] rounded-xl border border-line bg-page p-3 text-sm text-ink shadow-card">
    <div className="flex items-center gap-3"><p role="status" className="min-w-0 flex-1">{message}</p>
      <button aria-label="Dismiss update notification" className="size-7 shrink-0 rounded hover:bg-hover" onClick={() => setDismissed(true)}>×</button></div>
    {state.status === 'downloading' && <progress aria-label="Update download" max={100} value={state.percent ?? 0} className="mt-2 h-1 w-full accent-current" />}
    {state.status === 'ready' && <><p className="mt-1 text-xs text-ink-3">Restart when your work is finished. Active tasks and terminals will stop.</p>
      <button className="mt-2 rounded-lg bg-ink px-3 py-1.5 text-page" onClick={() => void act('restart')}>Restart to update</button></>}
    {state.status === 'error' && <button className="mt-2 rounded-lg bg-hover px-3 py-1.5" onClick={() => void act('check')}>Try again</button>}
  </div>;
}
