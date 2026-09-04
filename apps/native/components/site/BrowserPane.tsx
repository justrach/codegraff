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
  browserInput,
  browserMap,
  browserNav,
  browserNavigate,
  browserOpen,
  browserStatus,
  browserViewport,
  frameUrl,
  hitTest,
  type ElementMap,
  type MapElement,
  type PageInfo,
} from "@/lib/browser-client";
import type { BrowserPin, PinRect } from "@/lib/browser/annotations";
import { IconCrossSmall, IconGlobe } from "@/lib/icons";

/* ─────────────────────────────────────────────────────────
 * BROWSER PANE
 * The sidecar: a live picture of the headless Chrome tab Kuri drives for
 * this chat. Browse mode forwards the pointer, wheel and keyboard. Annotate
 * mode pins the element under a click, instantly: the page's pinnable
 * elements are fetched as one map (boxes, names, selectors, Kuri refs) and
 * hit-tested here, so hover and click never wait on the network. Pins are
 * kept in page coordinates and follow the page as it scrolls. Nothing is
 * injected into the page, so any site works.
 * ───────────────────────────────────────────────────────── */

type Mode = "browse" | "annotate";

const FRAME_QUALITY = 55;
const FRAME_GAP_MS = 160;
const HIDDEN_GAP_MS = 2000;
const MOVE_GAP_MS = 60;
const MAP_REFRESH_MS = 2500;
const MAP_SETTLE_MS = 350;

const PIN_STYLE = "flex size-5 items-center justify-center rounded-full bg-accent text-[10.5px] font-semibold text-white shadow-btn";

/** The page's viewport width: "fit" is the pane's own width, 1:1 pixels; a
 * number is a wider (tablet, laptop) layout drawn scaled down to the pane,
 * so a site can be pinned in the layout it will actually ship with. */
type Preset = "fit" | 768 | 1024 | 1280;
const PRESETS: readonly Preset[] = ["fit", 768, 1024, 1280];
const PRESET_KEY = "graff.native.browser.width";
const LAST_URL_KEY = "graff.native.browser.lastUrl";
const PANE_WIDTH_KEY = "graff.native.browser.paneWidth";

/** How wide the pane itself is. Wide enough to read, never so wide that the
 * chat beside it becomes a column of single words. */
const PANE_DEFAULT = 560;
const PANE_MIN = 380;
const PANE_CHAT_MIN = 520;

function clampPaneWidth(px: number): number {
  const room = typeof window === "undefined" ? 1440 : window.innerWidth;
  return Math.round(Math.min(Math.max(px, PANE_MIN), Math.max(PANE_MIN, room - PANE_CHAT_MIN)));
}

function loadPaneWidth(): number {
  try {
    const n = Number(localStorage.getItem(PANE_WIDTH_KEY));
    if (Number.isFinite(n) && n > 0) return n;
  } catch {
    // no storage
  }
  return PANE_DEFAULT;
}

function loadPreset(): Preset {
  try {
    const raw = localStorage.getItem(PRESET_KEY);
    if (raw === "fit") return "fit";
    const n = Number(raw);
    if (PRESETS.includes(n as Preset)) return n as Preset;
  } catch {
    // no storage
  }
  return "fit";
}

/** The page a workspace's pane last showed, so reopening it lands there. */
function loadLastUrl(key: string | undefined): string | null {
  if (!key) return null;
  try {
    return localStorage.getItem(`${LAST_URL_KEY}:${key}`);
  } catch {
    return null;
  }
}

function saveLastUrl(key: string | undefined, url: string): void {
  if (!key || !url || url === "about:blank") return;
  try {
    localStorage.setItem(`${LAST_URL_KEY}:${key}`, url);
  } catch {
    // no storage
  }
}

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

function elementLabel(el: { role: string; tag: string; name: string }): string {
  return `${el.role || el.tag}${el.name ? ` “${el.name}”` : ""}`;
}

/** Where a pin's marker sits now: its click point, moved by however far the
 * page has scrolled since it was placed. Null when it is off screen. */
function markerAt(pin: BrowserPin, map: ElementMap | null): { x: number; y: number } | null {
  if (!pin.doc) return pin.point;
  const scrollX = map?.scrollX ?? 0;
  const scrollY = map?.scrollY ?? 0;
  const x = pin.doc.x + (pin.point.x - pin.element.rect.x) - scrollX;
  const y = pin.doc.y + (pin.point.y - pin.element.rect.y) - scrollY;
  const vw = map?.vw ?? Infinity;
  const vh = map?.vh ?? Infinity;
  if (x < 0 || y < 0 || x > vw || y > vh) return null;
  return { x, y };
}

function pinBox(pin: BrowserPin, map: ElementMap | null): PinRect {
  if (!pin.doc) return pin.element.rect;
  return { x: pin.doc.x - (map?.scrollX ?? 0), y: pin.doc.y - (map?.scrollY ?? 0), w: pin.doc.w, h: pin.doc.h };
}

export default function BrowserPane({
  chat,
  pins,
  onPinsChange,
  onAsk,
  onClose,
  initialUrl,
  memoryKey,
}: {
  /** The chat handle; the tab is the chat's own, like its agent. */
  chat: string;
  pins: BrowserPin[];
  onPinsChange: (next: BrowserPin[]) => void;
  /** Send the pins to the agent now, with a default request. */
  onAsk?: () => void;
  onClose: () => void;
  initialUrl?: string;
  /** What to remember the last page under (the workspace path): a pane
   * that opens on a blank tab goes back there. */
  memoryKey?: string;
}) {
  const [info, setInfo] = useState<PageInfo | null>(null);
  const [url, setUrl] = useState(initialUrl ?? "");
  const [mode, setMode] = useState<Mode>("browse");
  const [src, setSrc] = useState<string | null>(null);
  const [busy, setBusy] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [map, setMap] = useState<ElementMap | null>(null);
  const [hoverEl, setHoverEl] = useState<MapElement | null>(null);
  const [editing, setEditing] = useState<number | null>(null);
  const [preset, setPreset] = useState<Preset>(() => loadPreset());
  // Server and first client render must agree, so the stored width is read
  // after mount rather than in the initial state.
  const [paneWidth, setPaneWidth] = useState(PANE_DEFAULT);
  const [dragging, setDragging] = useState(false);
  const presetRef = useRef<Preset>(preset);
  presetRef.current = preset;
  const frameRef = useRef<HTMLDivElement>(null);
  const imgRef = useRef<HTMLImageElement>(null);
  const urlRef = useRef<HTMLInputElement>(null);
  const noteRef = useRef<HTMLInputElement>(null);
  const lastMove = useRef(0);
  const mapSeq = useRef(0);
  const settleTimer = useRef(0);
  const infoRef = useRef<PageInfo | null>(null);
  infoRef.current = info;
  const mapRef = useRef<ElementMap | null>(null);
  mapRef.current = map;

  /** The viewport to give the page: the frame's own size, or the chosen
   * width with the height that keeps the frame's aspect, so the scaled
   * picture fills the frame exactly and pins land where they were clicked. */
  const paneSize = useCallback(() => {
    const el = frameRef.current;
    const frame = el
      ? { width: Math.max(320, Math.round(el.clientWidth)), height: Math.max(240, Math.round(el.clientHeight)) }
      : { width: 960, height: 640 };
    const p = presetRef.current;
    if (p === "fit") return frame;
    return { width: p, height: Math.max(240, Math.round((p * frame.height) / frame.width)) };
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
        saveLastUrl(memoryKey, next.url);
      } catch (err) {
        setError(err instanceof Error ? err.message : String(err));
      } finally {
        setBusy(null);
      }
    },
    [chat, paneSize, memoryKey],
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
          // A blank tab (the browser was restarted, or the chat never
          // navigated) goes back to the workspace's last page.
          const back = initialUrl ?? loadLastUrl(memoryKey);
          if (status.tab.url === "about:blank" && back) void open(back);
          return;
        }
      } catch {
        // status is best effort; fall through to open
      }
      if (!cancelled) void open(initialUrl ?? loadLastUrl(memoryKey) ?? "");
    })();
    return () => {
      cancelled = true;
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [chat]);

  // The workspace can arrive after the pane (a pane restored on boot mounts
  // before the chat's cwd is known): once it does, a still-blank tab goes
  // back to that workspace's last page.
  useEffect(() => {
    if (!memoryKey) return;
    const cur = infoRef.current;
    if (cur && cur.url !== "about:blank") return;
    const back = loadLastUrl(memoryKey);
    if (back && url === "") void open(back);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [memoryKey]);

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

  // The element map: what is pinnable on screen, and the scroll offset the
  // pins are placed against. Refreshed on a timer, after a scroll settles,
  // and whenever the page's address changes.
  const refreshMap = useCallback(async () => {
    if (!infoRef.current) return;
    const n = (mapSeq.current += 1);
    try {
      const next = await browserMap(chat);
      if (n !== mapSeq.current || !next) return;
      setMap(next);
      setHoverEl((cur) => (cur ? (next.els.find((el) => el.selector === cur.selector) ?? null) : null));
    } catch {
      // a page mid-navigation has no map; the last one stands until the next tick
    }
  }, [chat]);

  const pageUrl = info?.url ?? null;
  useEffect(() => {
    if (!tabId) return;
    void refreshMap();
    const timer = window.setInterval(() => void refreshMap(), MAP_REFRESH_MS);
    return () => window.clearInterval(timer);
  }, [tabId, pageUrl, refreshMap]);

  const scheduleMapRefresh = useCallback(() => {
    window.clearTimeout(settleTimer.current);
    settleTimer.current = window.setTimeout(() => void refreshMap(), MAP_SETTLE_MS);
  }, [refreshMap]);

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
          .then(() => refreshMap())
          .catch(() => undefined);
      }, 300);
    });
    observer.observe(el);
    return () => {
      observer.disconnect();
      window.clearTimeout(timer);
    };
  }, [chat, tabId, paneSize, refreshMap]);

  // A new width preset re-sizes the page's viewport; the picture, drawn at
  // the frame's size, shows the wider layout scaled down.
  useEffect(() => {
    try {
      localStorage.setItem(PRESET_KEY, String(preset));
    } catch {
      // no storage
    }
    if (!tabId) return;
    const { width, height } = paneSize();
    void browserViewport(chat, width, height)
      .then((v) => setInfo((c) => (c ? { ...c, ...v } : c)))
      .then(() => refreshMap())
      .catch(() => undefined);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [preset]);

  // Title and address follow the page (links clicked inside it, redirects).
  useEffect(() => {
    if (!tabId) return;
    const timer = window.setInterval(() => {
      void browserNav(chat, "info")
        .then((next) => {
          setInfo((cur) => (cur && (cur.url !== next.url || cur.title !== next.title) ? { ...cur, url: next.url, title: next.title } : cur));
          if (document.activeElement !== urlRef.current) setUrl(next.url === "about:blank" ? "" : next.url);
          saveLastUrl(memoryKey, next.url);
        })
        .catch(() => undefined);
    }, 2500);
    return () => window.clearInterval(timer);
  }, [chat, tabId, memoryKey]);

  useEffect(() => {
    if (editing !== null) window.setTimeout(() => noteRef.current?.focus(), 0);
  }, [editing]);

  // The pane's own width: restored on mount, kept within the window as it
  // is resized, saved once a drag ends.
  useEffect(() => {
    setPaneWidth(clampPaneWidth(loadPaneWidth()));
    const onResize = () => setPaneWidth((w) => clampPaneWidth(w));
    window.addEventListener("resize", onResize);
    return () => window.removeEventListener("resize", onResize);
  }, []);

  const dragFrom = useRef<{ x: number; width: number } | null>(null);

  const onHandleDown = (e: ReactPointerEvent<HTMLDivElement>) => {
    e.preventDefault();
    e.currentTarget.setPointerCapture(e.pointerId);
    dragFrom.current = { x: e.clientX, width: paneWidth };
    setDragging(true);
  };

  const onHandleMove = (e: ReactPointerEvent<HTMLDivElement>) => {
    const from = dragFrom.current;
    if (!from) return;
    // The pane sits on the right, so dragging left widens it.
    setPaneWidth(clampPaneWidth(from.width - (e.clientX - from.x)));
  };

  const endHandleDrag = (e: ReactPointerEvent<HTMLDivElement>) => {
    if (!dragFrom.current) return;
    dragFrom.current = null;
    setDragging(false);
    if (e.currentTarget.hasPointerCapture(e.pointerId)) e.currentTarget.releasePointerCapture(e.pointerId);
    try {
      localStorage.setItem(PANE_WIDTH_KEY, String(paneWidth));
    } catch {
      // no storage
    }
  };

  /** Keyboard resizing, and double-click to go back to the default. */
  const nudgeWidth = (px: number) => {
    const next = clampPaneWidth(px);
    setPaneWidth(next);
    try {
      localStorage.setItem(PANE_WIDTH_KEY, String(next));
    } catch {
      // no storage
    }
  };

  /** Frame pixels → the page's CSS pixels. */
  const toPage = (e: { clientX: number; clientY: number }) => {
    const img = imgRef.current;
    const cur = infoRef.current;
    if (!img || !cur) return null;
    const r = img.getBoundingClientRect();
    if (!r.width || !r.height) return null;
    return { x: ((e.clientX - r.left) / r.width) * cur.width, y: ((e.clientY - r.top) / r.height) * cur.height };
  };

  const updatePin = (id: number, patch: Partial<BrowserPin>) => onPinsChange(pins.map((p) => (p.id === id ? { ...p, ...patch } : p)));
  const removePin = (id: number) => {
    onPinsChange(pins.filter((p) => p.id !== id));
    if (editing === id) setEditing(null);
  };

  const onPointerMove = (e: ReactPointerEvent<HTMLDivElement>) => {
    const p = toPage(e);
    if (!p || busy) return;
    if (mode === "browse") {
      const now = performance.now();
      if (now - lastMove.current < MOVE_GAP_MS) return;
      lastMove.current = now;
      void browserInput(chat, { kind: "move", x: p.x, y: p.y }).catch(() => undefined);
      return;
    }
    const hit = hitTest(mapRef.current, p.x, p.y);
    setHoverEl((cur) => (cur === hit || (cur && hit && cur.i === hit.i) ? cur : hit));
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
    // One click pins. The note is optional and can be typed right away.
    const m = mapRef.current;
    const hit = hitTest(m, p.x, p.y);
    if (!m || !hit) {
      setEditing(null);
      return;
    }
    const { i: _i, ref, ...element } = hit;
    const pin: BrowserPin = {
      id: Date.now(),
      comment: "",
      url: m.url,
      title: m.title,
      ref,
      element,
      point: { x: p.x, y: p.y },
      doc: { x: element.rect.x + m.scrollX, y: element.rect.y + m.scrollY, w: element.rect.w, h: element.rect.h },
    };
    onPinsChange([...pins, pin]);
    setEditing(pin.id);
  };

  const onWheel = (e: ReactWheelEvent<HTMLDivElement>) => {
    if (busy) return;
    const p = toPage(e);
    if (!p) return;
    void browserInput(chat, { kind: "wheel", x: p.x, y: p.y, deltaX: e.deltaX, deltaY: e.deltaY }).catch(() => undefined);
    scheduleMapRefresh();
  };

  /** Scroll the page by `dy` CSS pixels from the middle of the viewport. */
  const scrollPage = (dy: number) => {
    const cur = infoRef.current;
    if (!cur || busy) return;
    void browserInput(chat, { kind: "wheel", x: cur.width / 2, y: cur.height / 2, deltaX: 0, deltaY: dy }).catch(() => undefined);
    scheduleMapRefresh();
  };

  const onKeyDown = (e: ReactKeyboardEvent<HTMLDivElement>) => {
    if (e.target !== frameRef.current) return;
    // Cmd/Ctrl+L: the address bar, as in a browser.
    if ((e.metaKey || e.ctrlKey) && !e.altKey && e.key.toLowerCase() === "l") {
      e.preventDefault();
      urlRef.current?.focus();
      urlRef.current?.select();
      return;
    }
    if (mode === "annotate") {
      // Keys do not reach the page in this mode, so scroll it from here.
      const page = (infoRef.current?.height ?? 600) * 0.85;
      const step: Record<string, number> = {
        ArrowDown: 80,
        ArrowUp: -80,
        PageDown: page,
        PageUp: -page,
        " ": e.shiftKey ? -page : page,
        End: 1_000_000,
        Home: -1_000_000,
      };
      if (e.key === "Escape") setEditing(null);
      else if (e.key in step && !e.metaKey && !e.ctrlKey && !e.altKey) {
        e.preventDefault();
        scrollPage(step[e.key]);
      }
      return;
    }
    if (busy || e.metaKey || e.ctrlKey || e.altKey) return;
    e.preventDefault();
    if (e.key.length === 1) void browserInput(chat, { kind: "type", text: e.key }).catch(() => undefined);
    else void browserInput(chat, { kind: "key", key: e.key }).catch(() => undefined);
  };

  const go = (target: string) => {
    const t = target.trim();
    if (t) void open(t);
  };

  const pageW = info?.width ?? 1;
  const pageH = info?.height ?? 1;
  const samePage = (p: BrowserPin) => !info || p.url === info.url;
  const editingPin = editing !== null ? (pins.find((p) => p.id === editing) ?? null) : null;
  // Anchor the note editor to the marker, but never unmount it while a pin is
  // being edited: a map refresh can report the marker off screen for one tick
  // (or the pin can really be scrolled away), and unmounting mid-typing drops
  // the input's focus and everything typed after it. Fall back to the pin's
  // last known point, clamped into the frame.
  const editingAt = editingPin
    ? (markerAt(editingPin, map) ?? { x: Math.min(pageW - 1, Math.max(0, editingPin.point.x)), y: Math.min(pageH - 1, Math.max(0, editingPin.point.y)) })
    : null;
  // Open the editor above the marker in the lower part of the frame so it is
  // not clipped by the frame's bottom edge or hidden behind the pin list.
  const editorAbove = !!editingAt && editingAt.y > pageH * 0.55;

  return (
    <aside
      className="relative hidden shrink-0 flex-col overflow-hidden rounded-[14px] border border-line bg-page lg:flex"
      style={{ width: paneWidth, animation: "fade-in 300ms ease both" }}
    >
      <div
        role="separator"
        aria-orientation="vertical"
        aria-label="Resize the browser pane"
        aria-valuenow={paneWidth}
        aria-valuemin={PANE_MIN}
        tabIndex={0}
        onPointerDown={onHandleDown}
        onPointerMove={onHandleMove}
        onPointerUp={endHandleDrag}
        onPointerCancel={endHandleDrag}
        onDoubleClick={() => nudgeWidth(PANE_DEFAULT)}
        onKeyDown={(e) => {
          if (e.key === "ArrowLeft") nudgeWidth(paneWidth + (e.shiftKey ? 80 : 20));
          else if (e.key === "ArrowRight") nudgeWidth(paneWidth - (e.shiftKey ? 80 : 20));
          else return;
          e.preventDefault();
        }}
        title="Drag to resize · double-click to reset"
        className={`absolute inset-y-0 left-0 z-20 w-2 cursor-col-resize touch-none transition-colors ${
          dragging ? "bg-accent/60" : "hover:bg-accent/30 focus-visible:bg-accent/40"
        }`}
      />
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
                setHoverEl(null);
                setEditing(null);
                if (m === "annotate") void refreshMap();
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
          onFocus={(e) => e.currentTarget.select()}
          spellCheck={false}
          placeholder="localhost:3000 or a URL"
          aria-label="Address"
          title="Address (Cmd/Ctrl+L from the page)"
          className="h-7 min-w-0 flex-1 rounded-[7px] bg-field px-2 font-mono text-[12px] text-ink shadow-hairline outline-none placeholder:text-ink-3 focus:bg-hover"
        />
        <button type="submit" className="h-7 shrink-0 rounded-[7px] bg-hover-2 px-2.5 text-[12px] font-medium text-ink transition-colors hover:bg-line-strong">
          Go
        </button>
        <select
          value={String(preset)}
          onChange={(e) => setPreset(e.target.value === "fit" ? "fit" : (Number(e.target.value) as Preset))}
          aria-label="Page width"
          title="Page width: the pane's own width at 1:1, or a wider layout scaled to fit"
          className="h-7 shrink-0 cursor-pointer rounded-[7px] bg-hover-2 pl-1.5 pr-1 text-[11.5px] font-medium text-ink outline-none transition-colors hover:bg-line-strong"
        >
          {PRESETS.map((p) => (
            <option key={String(p)} value={String(p)}>
              {p === "fit" ? "Fit" : `${p}px`}
            </option>
          ))}
        </select>
      </form>

      <div
        ref={frameRef}
        tabIndex={0}
        role="application"
        aria-label={mode === "browse" ? "Page, keyboard and pointer forwarded" : "Page, click an element to pin it"}
        onPointerMove={onPointerMove}
        onPointerDown={onPointerDown}
        onPointerUp={onPointerUp}
        onPointerLeave={() => setHoverEl(null)}
        onWheel={onWheel}
        onKeyDown={onKeyDown}
        onContextMenu={(e) => e.preventDefault()}
        className="relative min-h-0 flex-1 overflow-hidden bg-inset outline-none focus-visible:shadow-[inset_0_0_0_2px_var(--accent)]"
        style={{ cursor: mode === "annotate" ? (hoverEl ? "pointer" : "crosshair") : "default" }}
      >
        {src && info ? (
          <div className="relative w-full">
            <img ref={imgRef} src={src} alt="" draggable={false} className="block w-full select-none" />
            <div className="pointer-events-none absolute inset-0">
              {hoverEl && mode === "annotate" && (
                <div
                  className="absolute rounded-[3px]"
                  style={{
                    left: pct(hoverEl.rect.x, pageW),
                    top: pct(hoverEl.rect.y, pageH),
                    width: pct(hoverEl.rect.w, pageW),
                    height: pct(hoverEl.rect.h, pageH),
                    boxShadow: "0 0 0 2px var(--accent), 0 0 0 9999px color-mix(in oklab, var(--accent) 8%, transparent)",
                  }}
                >
                  <span className="absolute -top-5 left-0 max-w-full truncate rounded-[4px] bg-accent px-1 text-[10px] font-medium whitespace-nowrap text-white">
                    {hoverEl.ref ? `@${hoverEl.ref} · ` : ""}
                    {elementLabel(hoverEl)}
                  </span>
                </div>
              )}
              {pins.filter(samePage).map((pin) => {
                const box = pinBox(pin, map);
                return (
                  <div
                    key={`box-${pin.id}`}
                    className="absolute rounded-[3px]"
                    style={{
                      left: pct(box.x, pageW),
                      top: pct(box.y, pageH),
                      width: pct(box.w, pageW),
                      height: pct(box.h, pageH),
                      boxShadow: editing === pin.id ? "0 0 0 2px var(--accent)" : "0 0 0 1.5px color-mix(in oklab, var(--accent) 70%, transparent)",
                    }}
                  />
                );
              })}
            </div>
            <div className="pointer-events-none absolute inset-0">
              {pins.filter(samePage).map((pin) => {
                const at = markerAt(pin, map);
                if (!at) return null;
                return (
                  <button
                    key={pin.id}
                    type="button"
                    title={pin.comment || elementLabel(pin.element)}
                    onPointerDown={(e) => e.stopPropagation()}
                    onPointerUp={(e) => {
                      e.stopPropagation();
                      setEditing(pin.id);
                    }}
                    className="pointer-events-auto absolute"
                    style={{ left: pct(at.x, pageW), top: pct(at.y, pageH), transform: "translate(-50%, -50%)" }}
                  >
                    <span className={`${PIN_STYLE} ${editing === pin.id ? "ring-2 ring-white" : ""}`}>{pins.indexOf(pin) + 1}</span>
                  </button>
                );
              })}
            </div>
            {editingPin && editingAt && (
              <form
                className="absolute z-10 flex w-[280px] flex-col gap-1.5 rounded-[10px] bg-surface p-2 shadow-overlay"
                style={{
                  left: `min(calc(${pct(editingAt.x, pageW)} + 14px), calc(100% - 290px))`,
                  ...(editorAbove
                    ? { bottom: `min(calc(100% - ${pct(editingAt.y, pageH)} + 14px), calc(100% - 110px))` }
                    : { top: `min(calc(${pct(editingAt.y, pageH)} + 14px), calc(100% - 110px))` }),
                  animation: "pop-in 160ms cubic-bezier(0.23,1,0.32,1) both",
                }}
                onSubmit={(e) => {
                  e.preventDefault();
                  setEditing(null);
                }}
                onPointerDown={(e) => e.stopPropagation()}
                onPointerUp={(e) => e.stopPropagation()}
                onPointerMove={(e) => e.stopPropagation()}
                onWheel={(e) => e.stopPropagation()}
              >
                <div className="truncate text-[11.5px] text-ink-3" title={editingPin.element.selector}>
                  <span className="mr-1 font-semibold text-ink">#{pins.indexOf(editingPin) + 1}</span>
                  {editingPin.ref ? <span className="mr-1 font-mono text-accent-ink">@{editingPin.ref}</span> : null}
                  {elementLabel(editingPin.element)}
                </div>
                <input
                  ref={noteRef}
                  value={editingPin.comment}
                  onChange={(e) => updatePin(editingPin.id, { comment: e.target.value })}
                  onKeyDown={(e) => {
                    e.stopPropagation();
                    if (e.key === "Escape") setEditing(null);
                  }}
                  placeholder="What should change here? (optional)"
                  aria-label="Note for this pin"
                  className="h-7 w-full rounded-[7px] bg-field px-2 text-[12.5px] text-ink shadow-hairline outline-none placeholder:text-ink-3 focus:bg-hover"
                />
                <div className="flex items-center gap-1">
                  <button
                    type="button"
                    onClick={() => removePin(editingPin.id)}
                    className="h-6 rounded-full px-2 text-[11.5px] font-medium text-red hover:bg-hover"
                  >
                    Remove
                  </button>
                  <span className="flex-1" />
                  <button type="submit" className="h-6 rounded-full bg-ink px-2.5 text-[11.5px] font-medium text-canvas hover:opacity-90">
                    Done
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

      <div className="max-h-36 shrink-0 overflow-y-auto border-t border-line">
        {pins.length === 0 ? (
          <p className="px-3 py-2 text-[11.5px] text-ink-3">
            {mode === "annotate"
              ? "Click any element to pin it. Add a note if you like. Pins go to the agent with your next message."
              : "Browse: clicks, scrolling and typing go to the page. Switch to Annotate to pin elements for the agent."}
          </p>
        ) : (
          <div className="flex flex-col px-2 py-1.5">
            <div className="flex items-center gap-2 px-1.5 pb-1">
              <span className="min-w-0 flex-1 truncate text-[11.5px] text-ink-3">
                {pins.length} pin{pins.length === 1 ? "" : "s"} · sent with your next message
              </span>
              {onAsk && (
                <button
                  type="button"
                  onClick={onAsk}
                  className="h-6 shrink-0 rounded-full bg-ink px-2.5 text-[11.5px] font-medium text-canvas hover:opacity-90"
                >
                  Ask graff
                </button>
              )}
              <button
                type="button"
                onClick={() => {
                  onPinsChange([]);
                  setEditing(null);
                }}
                className="h-6 shrink-0 rounded-full px-2 text-[11.5px] font-medium text-ink-3 hover:bg-hover hover:text-ink"
              >
                Clear
              </button>
            </div>
            {pins.map((pin, i) => (
              <div
                key={pin.id}
                className={`group flex h-7 items-center gap-2 rounded-[7px] px-1.5 ${editing === pin.id ? "bg-hover" : "hover:bg-hover"}`}
              >
                <button
                  type="button"
                  onClick={() => setEditing(pin.id)}
                  title={`${pin.comment ? `${pin.comment} — ` : ""}${elementLabel(pin.element)}\n${pin.element.selector}`}
                  className="flex min-w-0 flex-1 items-center gap-2 text-left"
                >
                  <span className={`${PIN_STYLE} shrink-0`}>{i + 1}</span>
                  <span className="min-w-0 flex-1 truncate text-[12px] text-ink">
                    {pin.comment || <span className="text-ink-3">{elementLabel(pin.element)}</span>}
                  </span>
                  {pin.ref ? <span className="shrink-0 font-mono text-[10.5px] text-ink-3">@{pin.ref}</span> : null}
                </button>
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
          </div>
        )}
      </div>
    </aside>
  );
}
