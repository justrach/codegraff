"use client";
import { useEffect, useRef, useState } from "react";
import { desktop } from "@/lib/desktop";
import type { BrowserPin } from "@/lib/browser/annotations";
import type { PageInfo } from "@/lib/browser-client";

type Props = { chat: string; pins: BrowserPin[]; onPinsChange(pins: BrowserPin[]): void;
  onAsk?: () => void; onClose(): void; initialUrl?: string; memoryKey?: string };

export default function ElectronBrowserPane({ chat, pins, onPinsChange, onAsk, onClose, initialUrl, memoryKey }: Props) {
  const [url, setUrl] = useState(initialUrl || "");
  const [info, setInfo] = useState<(PageInfo & { canGoBack?: boolean; canGoForward?: boolean }) | null>(null);
  const [error, setError] = useState("");
  const [picking, setPicking] = useState(false);
  const [width, setWidth] = useState(520);
  const [find, setFind] = useState("");
  const [zoom, setZoom] = useState(1);
  const frame = useRef<HTMLDivElement>(null);
  const address = useRef<HTMLInputElement>(null);
  const callbacks = useRef({ pins, onPinsChange }); callbacks.current = { pins, onPinsChange };
  const storageKey = `graff.electron.browser.url:${memoryKey || chat}`;
  const layout = () => {
    const rect = frame.current?.getBoundingClientRect();
    if (rect) void desktop()?.browser(chat, "bounds", { x: rect.x, y: rect.y,
      width: rect.width, height: rect.height });
  };
  const layoutRef = useRef(layout); layoutRef.current = layout;
  const command = async (method: string, params?: Record<string, unknown>) => {
    try {
      setError(""); const next = await desktop()!.browser(chat, method, params);
      if (next?.url !== undefined) { setInfo(next); setUrl(next.url === "about:blank" ? "" : next.url); localStorage.setItem(storageKey, next.url); }
      layoutRef.current();
    } catch (err) { setError(err instanceof Error ? err.message : String(err)); }
  };
  useEffect(() => {
    const bridge = desktop()!;
    const unsubscribe = bridge.subscribe(event => {
      if (event.type === "layout") layoutRef.current();
      if (event.type === "released") { setInfo(null); setPicking(false); }
      if (event.chat !== chat) return;
      if (event.type === "info" && event.info) {
        if (event.info.ready === "loading") setPicking(false);
        setInfo(event.info); setUrl(event.info.url === "about:blank" ? "" : event.info.url);
        localStorage.setItem(storageKey, event.info.url);
      }
      if (event.type === "pick-cancelled") setPicking(false);
      if (event.type === "address") { address.current?.focus(); address.current?.select(); }
      if (event.type === "pin" && event.pin) {
        callbacks.current.onPinsChange([...callbacks.current.pins, event.pin]); setPicking(false);
      }
    });
    let alive = true;
    void bridge.browser(chat, "info").then(current => {
      if (!alive) return;
      if (current) { setInfo(current); setUrl(current.url); }
      else setUrl(initialUrl || localStorage.getItem(storageKey) || "");
      // A blank pane is just UI; it creates no browser renderer.
      if (initialUrl) void command("open", { url: initialUrl });
    });
    const observer = new ResizeObserver(() => layoutRef.current());
    if (frame.current) observer.observe(frame.current);
    const changed = () => layoutRef.current();
    window.addEventListener("resize", changed);
    return () => { alive = false; observer.disconnect(); unsubscribe(); window.removeEventListener("resize", changed);
      void bridge.browser(chat, "hide"); };
    // A browser view belongs to its chat, not a render of the composer.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [chat, storageKey]);
  useEffect(() => layoutRef.current(), [width, pins.length, error, picking]);
  useEffect(() => { void desktop()?.browser(chat, "pins", { pins }).catch(() => {}); }, [chat, pins, info?.url]);
  const button = "h-7 rounded-md px-2 text-xs hover:bg-hover disabled:opacity-40";
  return <aside className="relative flex shrink-0 flex-col overflow-hidden rounded-xl border border-line bg-page" style={{ width, maxWidth: "55vw" }}>
    <div role="separator" aria-label="Resize browser" aria-orientation="vertical" tabIndex={0}
      className="absolute inset-y-0 left-0 z-10 w-1.5 cursor-col-resize hover:bg-accent/30"
      onKeyDown={e => { if (e.key === "ArrowLeft") setWidth(w => Math.min(900, w + 20)); if (e.key === "ArrowRight") setWidth(w => Math.max(320, w - 20)); }}
      onPointerDown={e => e.currentTarget.setPointerCapture(e.pointerId)}
      onPointerMove={e => { if (e.currentTarget.hasPointerCapture(e.pointerId)) setWidth(Math.max(320, Math.min(900, window.innerWidth - e.clientX - 24))); }}
      onPointerUp={e => e.currentTarget.releasePointerCapture(e.pointerId)} />
    <header className="flex h-11 items-center gap-2 border-b border-line px-3">
      <span className="min-w-0 flex-1 truncate text-sm font-medium">{info?.ready === "loading" ? "Loading page…" : info?.title || "Browser"}</span>
      <button className={`${button} ${picking ? "bg-accent-tint text-accent-ink ring-1 ring-accent" : ""}`} aria-pressed={picking} disabled={!info || info.ready === "suspended"} onClick={() => { setPicking(!picking); void command("pick", { enabled: !picking }); }}>{picking ? "Cancel pin" : "Pin element"}</button>
      <button className={button} aria-label="Activity" onClick={() => void desktop()!.activity()}>Activity</button>
      <button className={button} aria-label="Close browser" onClick={() => { void desktop()!.browser(chat, "close"); onClose(); }}>×</button>
    </header>
    <form className="flex h-10 items-center gap-1 border-b border-line px-2" onSubmit={e => { e.preventDefault(); void command("open", { url }); }}>
      <button type="button" className={button} aria-label="Back" disabled={!info?.canGoBack} onClick={() => void command("back")}>←</button>
      <button type="button" className={button} aria-label="Forward" disabled={!info?.canGoForward} onClick={() => void command("forward")}>→</button>
      <button type="button" className={button} aria-label="Reload" onClick={() => void command("open", { url })}>↻</button>
      <input ref={address} className="h-7 min-w-0 flex-1 rounded-md bg-field px-2 text-xs outline-none" aria-label="Address" placeholder="Enter a URL" value={url} onChange={e => setUrl(e.target.value)} onFocus={e => e.currentTarget.select()} />
      <button className={button}>Go</button>
    </form>
    <div className="flex h-9 items-center gap-1 border-b border-line px-2">
      <input aria-label="Find in page" placeholder="Find in page" className="h-6 min-w-0 flex-1 rounded bg-field px-2 text-xs" value={find}
        onChange={e => { setFind(e.target.value); if (!e.target.value && info) void command("find", { text: "" }); }} onKeyDown={e => { if (e.key === "Enter" && find) void command("find", { text: find }); }} />
      <button className={button} disabled={!info || !find} onClick={() => void command("find", { text: find })}>Find</button>
      <button className={button} aria-label="Zoom out" disabled={!info || zoom <= 0.5} onClick={() => { const factor = Math.max(0.5, zoom - 0.1); setZoom(factor); void command("zoom", { factor }); }}>−</button>
      <button className={button} aria-label="Reset zoom" disabled={!info} onClick={() => { setZoom(1); void command("zoom", { factor: 1 }); }}>{Math.round(zoom * 100)}%</button>
      <button className={button} aria-label="Zoom in" disabled={!info || zoom >= 2} onClick={() => { const factor = Math.min(2, zoom + 0.1); setZoom(factor); void command("zoom", { factor }); }}>+</button>
    </div>
    {picking && <p role="status" className="border-b border-line bg-accent-tint px-3 py-2 text-xs text-accent-ink">Click the part of the page you want to discuss. Press Esc to cancel.</p>}
    {error && <p role="alert" className="px-3 py-2 text-xs text-red">{error}</p>}
    <div ref={frame} className="min-h-0 flex-1 bg-canvas">
      {(!info || info.ready === "suspended") && <div className="flex h-full flex-col items-center justify-center gap-3 p-8 text-center text-sm text-ink-3">
        <p>{info ? "Page suspended to save memory." : "Open a page to browse alongside graff."}</p>
        {url && <button className={button} onClick={() => void command("open", { url })}>Open page</button>}
      </div>}
    </div>
    <footer className="max-h-44 overflow-y-auto border-t border-line p-2 text-xs">
      {pins.length === 0 ? <p className="p-1 text-ink-3">{picking ? "Click an element in the page to attach it to your prompt." : "Select and type directly in the page. Pin an element to discuss it with graff."}</p> : <>
        <div className="flex items-center justify-between"><span>{pins.length} pinned elements</span><button className={`${button} bg-accent-tint text-accent-ink`} onClick={onAsk}>Use pins in chat</button></div>
        {pins.map((pin, i) => <div key={pin.id} className="flex items-center gap-2 py-1">
          <span title={`${pin.element.selector} · ${pin.url}`} className="max-w-32 truncate">{i + 1}. {pin.element.name || pin.element.tag}</span>
          <input autoFocus={i === pins.length - 1} aria-label={`Note for pin ${i + 1}`} className="min-w-0 flex-1 rounded bg-field px-2 py-1" placeholder="What should change?" value={pin.comment} onChange={e => onPinsChange(pins.map(p => p.id === pin.id ? { ...p, comment: e.target.value } : p))} />
          <button className={button} aria-label={`Remove pin ${i + 1}`} onClick={() => onPinsChange(pins.filter(p => p.id !== pin.id))}>×</button>
        </div>)}
      </>}
    </footer>
  </aside>;
}
