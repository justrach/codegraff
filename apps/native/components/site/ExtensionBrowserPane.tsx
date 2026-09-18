"use client";

import { useEffect, useRef, useState } from "react";
import type { BrowserPin } from "@/lib/browser/annotations";
import { extensionStatusRead, type ExtensionTab } from "@/lib/browser-client";

type Props = {
  chat: string;
  pins: BrowserPin[];
  onPinsChange(pins: BrowserPin[]): void;
  onAsk?: () => void;
  onClose(): void;
};

/** The user's own Chrome, paired through the Sidecar extension — the tab
 * stays in their window, and the harness drives it through the bridge.
 * No renderer, no frame polling: this pane is tabs, pairing, and pins. */
export default function ExtensionBrowserPane({ chat, pins, onPinsChange, onAsk, onClose }: Props) {
  const [tabs, setTabs] = useState<ExtensionTab[]>([]);
  const [paired, setPaired] = useState<boolean | null>(null);
  const [error, setError] = useState("");
  const [picking, setPicking] = useState(false);

  const refresh = async () => {
    try {
      setError("");
      const status = await extensionStatusRead();
      setPaired(status.paired);
      setTabs(status.tabs);
    } catch (err) {
      setError(err instanceof Error ? err.message : String(err));
    }
  };

  useEffect(() => {
    void refresh();
    const timer = setInterval(() => void refresh(), 5000);
    return () => clearInterval(timer);
    // The chat owns its pinned tab; a new chat re-reads which tabs exist.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [chat]);

  const pinsRef = useRef(pins);
  pinsRef.current = pins;
  const callbacks = useRef({ onPinsChange });
  callbacks.current = { onPinsChange };

  // Pins the user made in their own tabs arrive through the bridge; the
  // prompt runner drains them with the sidecar pins on the next send.
  useEffect(() => {
    const timer = setInterval(async () => {
      try {
        const res = await fetch("/api/extension/pins", { cache: "no-store" });
        if (!res.ok) return;
        const fresh = (await res.json()) as { pins: BrowserPin[] };
        if (fresh.pins.length > 0) callbacks.current.onPinsChange([...pinsRef.current, ...fresh.pins]);
      } catch {
        // the bridge is optional; a failed poll is silence, not an error
      }
    }, 3000);
    return () => clearInterval(timer);
  }, []);

  const command = async (type: string, params?: Record<string, unknown>) => {
    const res = await fetch("/api/extension", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ type, chat, params }),
    });
    const body = (await res.json()) as { result?: unknown; error?: string };
    if (!res.ok) throw new Error(body.error || `extension ${type} → ${res.status}`);
    return body.result;
  };

  const pick = async (enabled: boolean) => {
    setPicking(enabled);
    if (!enabled) return;
    try {
      await command("pick", { enabled: true });
    } catch (err) {
      setError(err instanceof Error ? err.message : String(err));
      setPicking(false);
    }
  };

  const button = "h-7 rounded-md px-2 text-xs hover:bg-hover disabled:opacity-40";
  return (
    <aside className="relative flex shrink-0 flex-col overflow-hidden rounded-xl border border-line bg-page" style={{ width: 420, maxWidth: "55vw" }}>
      <header className="flex h-11 items-center gap-2 border-b border-line px-3">
        <span className="min-w-0 flex-1 truncate text-sm font-medium">Your Chrome</span>
        <button className={`${button} ${picking ? "bg-accent-tint text-accent-ink ring-1 ring-accent" : ""}`} aria-pressed={picking}
          disabled={!paired} onClick={() => void pick(!picking)}>{picking ? "Cancel pin" : "Pin element"}</button>
        <button className={button} aria-label="Close browser" onClick={onClose}>×</button>
      </header>
      <div className="min-h-0 flex-1 overflow-y-auto p-2">
        {paired === null && <p className="p-2 text-xs text-ink-3">Checking for the paired extension…</p>}
        {paired === false && (
          <div className="flex h-full flex-col items-center justify-center gap-3 p-6 text-center text-sm text-ink-3">
            <p><b className="text-ink">Pair your Chrome to browse alongside graff.</b></p>
            <ol className="list-decimal pl-5 text-left text-xs leading-5">
              <li>Load <code>apps/chrome-extension</code> as an unpacked extension.</li>
              <li>Copy the pairing token from the harness server log.</li>
              <li>Paste it into the Sidecar popup and press Pair.</li>
            </ol>
            <button className={`${button} bg-accent-tint text-accent-ink`} onClick={() => void refresh()}>Check again</button>
          </div>
        )}
        {paired && tabs.length === 0 && <p className="p-2 text-xs text-ink-3">Paired, but no tabs reported yet — open a page in Chrome.</p>}
        {error && <p role="alert" className="px-2 py-1 text-xs text-red">{error}</p>}
        {tabs.map((t) => (
          <div key={t.id} className="flex items-center gap-2 rounded-lg px-2 py-1.5 hover:bg-hover" title={t.url}>
            <span className={`size-1.5 shrink-0 rounded-full ${t.active ? "bg-accent" : "bg-line"}`} />
            <span className="min-w-0 flex-1 truncate text-xs">{t.title || t.url || `Tab ${t.id}`}</span>
            <span className="shrink-0 truncate text-[11px] text-ink-3">{new URL(t.url || "about:blank").hostname || ""}</span>
          </div>
        ))}
        {picking && <p role="status" className="px-2 py-2 text-xs text-accent-ink">Click the part of the page you want to discuss — in your Chrome window. Press Esc there to cancel.</p>}
      </div>
      <footer className="max-h-44 overflow-y-auto border-t border-line p-2 text-xs">
        {pins.length === 0 ? <p className="p-1 text-ink-3">{picking ? "Click an element in your Chrome tab to attach it to your prompt." : "Pin an element in your Chrome tab to discuss it with graff."}</p> : <>
          <div className="flex items-center justify-between"><span>{pins.length} pinned {pins.length === 1 ? "element" : "elements"}</span><button className={`${button} bg-accent-tint text-accent-ink`} onClick={onAsk}>Send pins</button></div>
          {pins.map((pin, i) => <div key={pin.id} className="flex items-center gap-2 py-1">
            <span title={`${pin.element.selector} · ${pin.url}`} className="max-w-32 truncate">{i + 1}. {pin.element.name || pin.element.tag}</span>
            <input autoFocus={i === pins.length - 1} aria-label={`Note for pin ${i + 1}`} className="min-w-0 flex-1 rounded bg-field px-2 py-1" placeholder="What should change?" value={pin.comment} onChange={e => onPinsChange(pins.map(p => p.id === pin.id ? { ...p, comment: e.target.value } : p))} />
            <button className={button} aria-label={`Remove pin ${i + 1}`} onClick={() => onPinsChange(pins.filter(p => p.id !== pin.id))}>×</button>
          </div>)}
        </>}
      </footer>
    </aside>
  );
}
