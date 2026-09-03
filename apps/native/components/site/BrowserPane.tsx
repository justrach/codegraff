"use client";

import {
  useCallback,
  useEffect,
  useRef,
  useState,
  type KeyboardEvent as ReactKeyboardEvent,
  type PointerEvent as ReactPointerEvent,
  type WheelEvent as ReactWheelEvent,
} from "react";
import {
  browserHover,
  browserInput,
  browserInspect,
  browserNav,
  browserNavigate,
  browserOpen,
  browserStatus,
  browserViewport,
  frameUrl,
  type InspectHit,
  type PageInfo,
} from "@/lib/browser-client";
import type { BrowserPin, PinRect } from "@/lib/browser/annotations";
import { IconCrossSmall, IconGlobe } from "@/lib/icons";

/* ─────────────────────────────────────────────────────────
 * BROWSER PANE
 * The sidecar: a live picture of the headless Chrome tab Kuri drives for
 * this chat. In browse mode the pointer and keyboard are forwarded; in
 * annotate mode a click pins the element under it with a note. The pins
 * are drawn here, over the frame, from geometry the page reports — nothing
 * is injected into the page, so it works under any content security policy.
 * ───────────────────────────────────────────────────────── */

type Mode = "browse" | "annotate";

const FRAME_QUALITY = 55;
const FRAME_GAP_MS = 160;
const HIDDEN_GAP_MS = 2000;
const HOVER_GAP_MS = 90;
const MOVE_GAP_MS = 60;

const PIN_STYLE = "flex size-5 items-center justify-center rounded-full bg-accent text-[10.5px] font-semibold text-white shadow-btn";

function pct(n: number, of: number): string {
  return `${(n / Math.max(1, of)) * 100}%`;
}

function Glyph({ d, size = 13 }: { d: string; size?: number }) {
  return (
    <svg width={size} height={size} viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" aria-hidden>
      <path d={d} />
    </svg>
  );
}

function BarButton({ label, onClick, disabled, children }: { label: string; onClick: () => void; disabled?: boolean; children: React.ReactNode }) {
  return (
    <button
      type="button"
      aria-label={label}
      title={label}
      disabled={disabled}
      onClick={onClick}
      className="flex size-7 shrink-0 items-center justify-center rounded-[6px] text-ink-3 transition-colors duration-100 hover:bg-hover hover:text-ink disabled:opacity-40 disabled:hover:bg-transparent"
    >
      {children}
    </button>
  );
}

export default function BrowserPane({
  chat,
  pins,
  onPinsChange,
  onClose,
  initialUrl,
}: {
  /** The chat handle; the tab is the chat's own, like its agent. */
  chat: string;
  pins: BrowserPin[];
  onPinsChange: (next: BrowserPin[]) => void;
  onClose: () => void;
  initialUrl?: string;
}) {
  const [info, setInfo] = useState<PageInfo | null>(null);
  const [url, setUrl] = useState(initialUrl ?? "");
  const [mode, setMode] = useState<Mode>("browse");
  const [src, setSrc] = useState<string | null>(null);
  const [busy, setBusy] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [hover, setHover] = useState<PinRect | null>(null);
  const [draft, setDraft] = useState<{ x: number; y: number; hit: InspectHit } | null>(null);
  const [comment, setComment] = useState("");
  const frameRef = useRef<HTMLDivElement>(null);
  const imgRef = useRef<HTMLImageElement>(null);
  const urlRef = useRef<HTMLInputElement>(null);
  const commentRef = useRef<HTMLInputElement>(null);
  const lastMove = useRef(0);
  const lastHover = useRef(0);
  const infoRef = useRef<PageInfo | null>(null);
  infoRef.current = info;

  const paneSize = useCallback(() => {
    const el = frameRef.current;
    if (!el) return { width: 960, height: 640 };
    return { width: Math.max(320, Math.round(el.clientWidth)), height: Math.max(240, Math.round(el.clientHeight)) };
  }, []);

  const open = useCallback(
    async (target: string) => {
      setBusy(infoRef.current ? "Loading…" : "Starting the browser…");
      setError(null);
      try {
        const { width, height } = paneSize();
        const next = infoRef.current ? await browserNavigate(chat, target) : await browserOpen(chat, target, width, height);
        setInfo(next);
        setUrl(next.url === "about:blank" ? "" : next.url);
      } catch (err) {
        setError(err instanceof Error ? err.message : String(err));
      } finally {
        setBusy(null);
      }
    },
    [chat, paneSize],
  );

  // Adopt the chat's tab when it already exists (the pane was closed and
  // reopened); otherwise open one. Only this path spawns the browser.
  useEffect(() => {
    let cancelled = false;
    (async () => {
      try {
        const status = await browserStatus(chat);
        if (cancelled) return;
        if (status.tab) {
          setInfo(status.tab);
          setUrl(status.tab.url === "about:blank" ? "" : status.tab.url);
          const { width, height } = paneSize();
          void browserViewport(chat, width, height).catch(() => undefined);
          return;
        }
      } catch {
        // status is best effort; fall through to open
      }
      if (!cancelled) void open(initialUrl ?? "");
    })();
    return () => {
      cancelled = true;
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [chat]);

  // The picture: one JPEG after another, the next requested only once the
  // last has decoded. A hidden tab drops to one frame every two seconds —
  // near free, and the picture is fresh the moment the tab comes back.
  const tabId = info?.tabId ?? null;
  useEffect(() => {
    if (!tabId) return;
    let alive = true;
    let timer = 0;
    const loop = () => {
      if (!alive) return;
      const next = frameUrl(chat, FRAME_QUALITY, Date.now());
      const im = new Image();
      im.onload = () => {
        if (!alive) return;
        setSrc(next);
        timer = window.setTimeout(loop, document.hidden ? HIDDEN_GAP_MS : FRAME_GAP_MS);
      };
      im.onerror = () => {
        if (alive) timer = window.setTimeout(loop, 1200);
      };
      im.src = next;
    };
    loop();
    return () => {
      alive = false;
      window.clearTimeout(timer);
    };
  }, [chat, tabId]);

  // The viewport follows the pane, so the picture is 1:1 and stays crisp.
  useEffect(() => {
    const el = frameRef.current;
    if (!el || !tabId) return;
    let timer = 0;
    const observer = new ResizeObserver(() => {
      window.clearTimeout(timer);
      timer = window.setTimeout(() => {
        const { width, height } = paneSize();
        const cur = infoRef.current;
        if (!cur || (width === cur.width && height === cur.height)) return;
        void browserViewport(chat, width, height)
          .then((v) => setInfo((c) => (c ? { ...c, ...v } : c)))
          .catch(() => undefined);
      }, 300);
    });
    observer.observe(el);
    return () => {
      observer.disconnect();
      window.clearTimeout(timer);
    };
  }, [chat, tabId, paneSize]);

  // Title and address follow the page (links clicked inside it, redirects).
  useEffect(() => {
    if (!tabId) return;
    const timer = window.setInterval(() => {
      void browserNav(chat, "info")
        .then((next) => {
          setInfo((cur) => (cur && (cur.url !== next.url || cur.title !== next.title) ? { ...cur, url: next.url, title: next.title } : cur));
          if (document.activeElement !== urlRef.current) setUrl(next.url === "about:blank" ? "" : next.url);
        })
        .catch(() => undefined);
    }, 2500);
    return () => window.clearInterval(timer);
  }, [chat, tabId]);

  /** Frame pixels → the page's CSS pixels. */
  const toPage = (e: { clientX: number; clientY: number }) => {
    const img = imgRef.current;
    const cur = infoRef.current;
    if (!img || !cur) return null;
    const r = img.getBoundingClientRect();
    if (!r.width || !r.height) return null;
    return { x: ((e.clientX - r.left) / r.width) * cur.width, y: ((e.clientY - r.top) / r.height) * cur.height };
  };

  const onPointerMove = (e: ReactPointerEvent<HTMLDivElement>) => {
    const p = toPage(e);
    if (!p || busy) return;
    const now = performance.now();
    if (mode === "browse") {
      if (now - lastMove.current < MOVE_GAP_MS) return;
      lastMove.current = now;
      void browserInput(chat, { kind: "move", x: p.x, y: p.y }).catch(() => undefined);
      return;
    }
    if (now - lastHover.current < HOVER_GAP_MS) return;
    lastHover.current = now;
    void browserHover(chat, p.x, p.y)
      .then((hit) => setHover(hit?.rect ?? null))
      .catch(() => undefined);
  };

  const onPointerDown = (e: ReactPointerEvent<HTMLDivElement>) => {
    frameRef.current?.focus();
    const p = toPage(e);
    if (!p || busy) return;
    if (mode === "browse") {
      e.preventDefault();
      void browserInput(chat, { kind: "down", x: p.x, y: p.y, button: e.button === 2 ? "right" : "left" }).catch(() => undefined);
    }
  };

  const onPointerUp = (e: ReactPointerEvent<HTMLDivElement>) => {
    const p = toPage(e);
    if (!p || busy) return;
    if (mode === "browse") {
      void browserInput(chat, { kind: "up", x: p.x, y: p.y, button: e.button === 2 ? "right" : "left" }).catch(() => undefined);
      return;
    }
    if (e.button !== 0) return;
    setBusy("Reading the element…");
    void browserInspect(chat, p.x, p.y)
      .then((hit) => {
        if (!hit) return;
        setDraft({ x: p.x, y: p.y, hit });
        setComment("");
        setHover(hit.element.rect);
        window.setTimeout(() => commentRef.current?.focus(), 0);
      })
      .catch((err) => setError(err instanceof Error ? err.message : String(err)))
      .finally(() => setBusy(null));
  };

  const onWheel = (e: ReactWheelEvent<HTMLDivElement>) => {
    if (mode !== "browse" || busy) return;
    const p = toPage(e);
    if (!p) return;
    void browserInput(chat, { kind: "wheel", x: p.x, y: p.y, deltaX: e.deltaX, deltaY: e.deltaY }).catch(() => undefined);
  };

  const onKeyDown = (e: ReactKeyboardEvent<HTMLDivElement>) => {
    if (mode !== "browse" || busy || e.metaKey || e.ctrlKey || e.altKey) return;
    if (e.target !== frameRef.current) return;
    e.preventDefault();
    if (e.key.length === 1) void browserInput(chat, { kind: "type", text: e.key }).catch(() => undefined);
    else void browserInput(chat, { kind: "key", key: e.key }).catch(() => undefined);
  };

  const commitPin = () => {
    if (!draft) return;
    const pin: BrowserPin = {
      id: Date.now(),
      comment: comment.trim(),
      url: draft.hit.url,
      title: draft.hit.title,
      ref: draft.hit.ref,
      element: draft.hit.element,
      point: { x: draft.x, y: draft.y },
    };
    onPinsChange([...pins, pin]);
    setDraft(null);
    setComment("");
    setHover(null);
  };

  const removePin = (id: number) => onPinsChange(pins.filter((p) => p.id !== id));

  const go = (target: string) => {
    const t = target.trim();
    if (t) void open(t);
  };

  const pageW = info?.width ?? 1;
  const pageH = info?.height ?? 1;
  const samePage = (p: BrowserPin) => !info || p.url === info.url;

  return (
    <aside
      className="hidden w-[560px] shrink-0 flex-col overflow-hidden rounded-[14px] border border-line bg-page lg:flex"
      style={{ animation: "fade-in 300ms ease both" }}
    >
      <div className="flex h-11 shrink-0 items-center gap-2 border-b border-line px-3">
        <span className="flex size-5 items-center justify-center text-ink-2">
          <IconGlobe size={16} />
        </span>
        <span className="min-w-0 flex-1 truncate text-[13px] font-semibold text-ink" title={info?.url}>
          {info?.title || (info ? info.url : "Browser")}
        </span>
        <div className="flex h-7 shrink-0 items-center rounded-[7px] bg-hover p-0.5 text-[11.5px] font-medium">
          {(["browse", "annotate"] as const).map((m) => (
            <button
              key={m}
              type="button"
              aria-pressed={mode === m}
              onClick={() => {
                setMode(m);
                setHover(null);
                setDraft(null);
              }}
              className={`h-6 rounded-[6px] px-2 capitalize transition-colors ${mode === m ? "bg-surface text-ink shadow-hairline" : "text-ink-3 hover:text-ink"}`}
            >
              {m}
            </button>
          ))}
        </div>
        <button
          type="button"
          aria-label="Close browser"
          onClick={onClose}
          className="flex size-7 items-center justify-center rounded-[6px] text-ink-3 transition-colors duration-100 hover:bg-hover hover:text-ink"
        >
          <IconCrossSmall size={16} />
        </button>
      </div>

      <form
        className="flex h-9 shrink-0 items-center gap-1 border-b border-line px-2"
        onSubmit={(e) => {
          e.preventDefault();
          go(url);
        }}
      >
        <BarButton label="Back" disabled={!info} onClick={() => void browserNav(chat, "back").then(setInfo).catch(() => undefined)}>
          <Glyph d="M15 18l-6-6 6-6" />
        </BarButton>
        <BarButton label="Forward" disabled={!info} onClick={() => void browserNav(chat, "forward").then(setInfo).catch(() => undefined)}>
          <Glyph d="M9 18l6-6-6-6" />
        </BarButton>
        <BarButton label="Reload" disabled={!info} onClick={() => void browserNav(chat, "reload").then(setInfo).catch(() => undefined)}>
          <Glyph d="M21 12a9 9 0 1 1-3-6.7M21 3v6h-6" />
        </BarButton>
        <input
          ref={urlRef}
          value={url}
          onChange={(e) => setUrl(e.target.value)}
          spellCheck={false}
          placeholder="localhost:3000 or a URL"
          aria-label="Address"
          className="h-7 min-w-0 flex-1 rounded-[7px] bg-field px-2 font-mono text-[12px] text-ink shadow-hairline outline-none placeholder:text-ink-3 focus:bg-hover"
        />
        <button type="submit" className="h-7 shrink-0 rounded-[7px] bg-hover-2 px-2.5 text-[12px] font-medium text-ink transition-colors hover:bg-line-strong">
          Go
        </button>
      </form>

      <div
        ref={frameRef}
        tabIndex={0}
        role="application"
        aria-label={mode === "browse" ? "Page, keyboard and pointer forwarded" : "Page, click an element to annotate it"}
        onPointerMove={onPointerMove}
        onPointerDown={onPointerDown}
        onPointerUp={onPointerUp}
        onPointerLeave={() => setHover(null)}
        onWheel={onWheel}
        onKeyDown={onKeyDown}
        onContextMenu={(e) => e.preventDefault()}
        className="relative min-h-0 flex-1 overflow-hidden bg-inset outline-none focus-visible:shadow-[inset_0_0_0_2px_var(--accent)]"
        style={{ cursor: mode === "annotate" ? "crosshair" : "default" }}
      >
        {src && info ? (
          <div className="relative w-full">
            <img ref={imgRef} src={src} alt="" draggable={false} className="block w-full select-none" />
            <div className="pointer-events-none absolute inset-0">
              {hover && mode === "annotate" && (
                <div
                  className="absolute rounded-[3px]"
                  style={{
                    left: pct(hover.x, pageW),
                    top: pct(hover.y, pageH),
                    width: pct(hover.w, pageW),
                    height: pct(hover.h, pageH),
                    boxShadow: "0 0 0 2px var(--accent), 0 0 0 9999px color-mix(in oklab, var(--accent) 10%, transparent)",
                  }}
                />
              )}
              {pins.filter(samePage).map((pin) => (
                <div
                  key={pin.id}
                  className="absolute"
                  style={{ left: pct(pin.point.x, pageW), top: pct(pin.point.y, pageH), transform: "translate(-50%, -50%)" }}
                  title={pin.comment || pin.element.name}
                >
                  <span className={PIN_STYLE}>{pins.indexOf(pin) + 1}</span>
                </div>
              ))}
              {draft && (
                <div
                  className="absolute"
                  style={{ left: pct(draft.x, pageW), top: pct(draft.y, pageH), transform: "translate(-50%, -50%)" }}
                >
                  <span className={`${PIN_STYLE} animate-pulse`}>{pins.length + 1}</span>
                </div>
              )}
            </div>
            {draft && (
              <form
                className="absolute z-10 flex w-[280px] flex-col gap-1.5 rounded-[10px] bg-surface p-2 shadow-overlay"
                style={{
                  left: `min(calc(${pct(draft.x, pageW)} + 14px), calc(100% - 290px))`,
                  top: `min(calc(${pct(draft.y, pageH)} + 14px), calc(100% - 110px))`,
                  animation: "pop-in 160ms cubic-bezier(0.23,1,0.32,1) both",
                }}
                onSubmit={(e) => {
                  e.preventDefault();
                  commitPin();
                }}
                onPointerDown={(e) => e.stopPropagation()}
                onPointerUp={(e) => e.stopPropagation()}
                onPointerMove={(e) => e.stopPropagation()}
              >
                <div className="truncate text-[11.5px] text-ink-3" title={draft.hit.element.selector}>
                  {draft.hit.ref ? <span className="mr-1 font-mono text-accent-ink">@{draft.hit.ref}</span> : null}
                  {draft.hit.element.role || draft.hit.element.tag}
                  {draft.hit.element.name ? ` “${draft.hit.element.name}”` : ""}
                </div>
                <input
                  ref={commentRef}
                  value={comment}
                  onChange={(e) => setComment(e.target.value)}
                  onKeyDown={(e) => {
                    e.stopPropagation();
                    if (e.key === "Escape") {
                      setDraft(null);
                      setHover(null);
                    }
                  }}
                  placeholder="What should change here?"
                  aria-label="Annotation"
                  className="h-7 w-full rounded-[7px] bg-field px-2 text-[12.5px] text-ink shadow-hairline outline-none placeholder:text-ink-3 focus:bg-hover"
                />
                <div className="flex items-center justify-end gap-1">
                  <button
                    type="button"
                    onClick={() => {
                      setDraft(null);
                      setHover(null);
                    }}
                    className="h-6 rounded-full px-2 text-[11.5px] font-medium text-ink-2 hover:bg-hover hover:text-ink"
                  >
                    Cancel
                  </button>
                  <button type="submit" className="h-6 rounded-full bg-ink px-2.5 text-[11.5px] font-medium text-canvas hover:opacity-90">
                    Pin
                  </button>
                </div>
              </form>
            )}
          </div>
        ) : (
          <div className="flex h-full items-center justify-center px-6 text-center text-[12.5px] text-ink-3">
            {busy ?? (error ? "" : "Enter an address above.")}
          </div>
        )}
        {busy && src && (
          <div className="pointer-events-none absolute top-2 left-1/2 -translate-x-1/2 rounded-full bg-surface px-2.5 py-1 text-[11.5px] text-ink-2 shadow-overlay">
            {busy}
          </div>
        )}
        {error && (
          <div className="absolute inset-x-2 bottom-2 rounded-[8px] bg-surface px-2.5 py-1.5 text-[12px] text-red shadow-overlay">
            {error}
          </div>
        )}
      </div>

      <div className="max-h-44 shrink-0 overflow-y-auto border-t border-line">
        {pins.length === 0 ? (
          <p className="px-3 py-2 text-[11.5px] text-ink-3">
            {mode === "annotate"
              ? "Click any element to pin it with a note. Pins go to the agent with your next message."
              : "Browse: clicks, scrolling and typing go to the page. Switch to Annotate to pin elements for the agent."}
          </p>
        ) : (
          <div className="flex flex-col px-2 py-1.5">
            {pins.map((pin, i) => (
              <div key={pin.id} className="group flex min-h-8 items-center gap-2 rounded-[7px] px-1.5 py-1 hover:bg-hover">
                <span className={`${PIN_STYLE} shrink-0`}>{i + 1}</span>
                <div className="min-w-0 flex-1">
                  <div className="truncate text-[12px] text-ink">{pin.comment || <span className="text-ink-3">no note</span>}</div>
                  <div className="truncate font-mono text-[10.5px] text-ink-3" title={pin.element.selector}>
                    {pin.ref ? `@${pin.ref} · ` : ""}
                    {pin.element.role || pin.element.tag}
                    {pin.element.name ? ` “${pin.element.name}”` : ""}
                  </div>
                </div>
                <button
                  type="button"
                  aria-label="Remove pin"
                  onClick={() => removePin(pin.id)}
                  className="flex size-6 shrink-0 items-center justify-center rounded-[5px] text-ink-3 opacity-0 transition-opacity hover:bg-hover-2 hover:text-ink group-hover:opacity-100 focus:opacity-100"
                >
                  <IconCrossSmall size={14} />
                </button>
              </div>
            ))}
            <button
              type="button"
              onClick={() => onPinsChange([])}
              className="mt-0.5 self-start rounded px-1.5 py-0.5 text-[11.5px] font-medium text-ink-3 hover:bg-hover hover:text-ink"
            >
              Clear all
            </button>
          </div>
        )}
      </div>
    </aside>
  );
}
