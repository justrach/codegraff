/** Browser side of /api/browser and the Chrome extension bridge: the
 * sidecar's live page, its controls, and the element lookups behind
 * annotations. Extension rows (the user's own Chrome, paired explicitly)
 * speak the same method set; see apps/chrome-extension for the other end. */

import type { KuriState } from "@/lib/browser/kuri-supervisor";
import type { KuriHandle, PinElement } from "@/lib/browser/annotations";
async function extensionCall<T>(chat: string, method: string, params: Record<string, unknown> = {}): Promise<T> {
  const res = await fetch("/api/extension", {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ type: method, chat, params }),
    cache: "no-store",
  });
  const body = await res.json();
  if (!res.ok) throw new Error(body.error || `extension ${method} → ${res.status}`);
  return body.result as T;
}

import { desktop } from "./desktop";

const BASE = "/api/browser";

export type PageInfo = { tabId: string; url: string; title: string; width: number; height: number; ready: string };

export type BrowserStatus = { kuri: KuriState; tab: PageInfo | null };

export type ExtensionTab = { id: number; windowId: number; url: string; title: string; active: boolean };

export type ExtensionStatus = { paired: boolean; lastPollMs: number | null; tabs: ExtensionTab[]; pendingPins: number };

export type InspectHit = { element: PinElement; ref: string | null; url: string; title: string };

export type HoverHit = { rect: PinElement["rect"]; tag: string };

/** One pinnable element on screen, as the page reported it. */
export type MapElement = PinElement & { i: number; ref: string | null };

/** The page's pinnable elements at one moment, with the scroll offset they
 * were measured at, so pins can be placed in page coordinates. */
export type ElementMap = {
  url: string;
  title: string;
  vw: number;
  vh: number;
  scrollX: number;
  scrollY: number;
  els: MapElement[];
};

/** The smallest mapped element under a viewport point, or null. */
export function hitTest(map: ElementMap | null, x: number, y: number): MapElement | null {
  if (!map) return null;
  let best: MapElement | null = null;
  let bestArea = Infinity;
  for (const el of map.els) {
    const r = el.rect;
    if (x < r.x || y < r.y || x > r.x + r.w || y > r.y + r.h) continue;
    const area = r.w * r.h;
    if (area < bestArea) {
      best = el;
      bestArea = area;
    }
  }
  return best;
}

export type InputEvent =
  | { kind: "move" | "down" | "up" | "click"; x: number; y: number; button?: "left" | "right" | "middle" }
  | { kind: "wheel"; x: number; y: number; deltaX: number; deltaY: number }
  | { kind: "key"; key: string }
  | { kind: "type"; text: string };

export async function browserCall<T>(chat: string, method: string, params?: Record<string, unknown>): Promise<T> {
  if (desktop()) return desktop()!.browser<T>(chat, method, params);
  const res = await fetch(BASE, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ chat, method, params }),
    cache: "no-store",
  });
  const text = await res.text();
  let body: unknown = null;
  try {
    body = text ? JSON.parse(text) : null;
  } catch {
    body = null;
  }
  if (!res.ok) {
    const detail = body && typeof body === "object" && typeof (body as { error?: unknown }).error === "string" ? (body as { error: string }).error : text;
    throw new Error(detail || `browser ${method} → ${res.status}`);
  }
  return body as T;
}

export async function browserStatus(chat: string): Promise<BrowserStatus> {
  const res = await fetch(`${BASE}?chat=${encodeURIComponent(chat)}`, { cache: "no-store" });
  if (!res.ok) throw new Error(`browser status → ${res.status}`);
  return (await res.json()) as BrowserStatus;
}

/** The current picture of the chat's tab; `tick` defeats the image cache. */
export function frameUrl(chat: string, quality: number, tick: number): string {
  return `${BASE}?chat=${encodeURIComponent(chat)}&frame=1&q=${quality}&t=${tick}`;
}

export const browserWarm = () => browserCall<{ kuri: KuriState }>("default", "warm");
export const browserOpen = (chat: string, url: string, width: number, height: number) =>
  browserCall<PageInfo>(chat, "open", { url, width, height });
export const browserNavigate = (chat: string, url: string) => browserCall<PageInfo>(chat, "navigate", { url });
export const browserNav = (chat: string, method: "back" | "forward" | "reload" | "info") => browserCall<PageInfo>(chat, method);
export const browserViewport = (chat: string, width: number, height: number) =>
  browserCall<{ width: number; height: number }>(chat, "viewport", { width, height });
export const browserInput = (chat: string, event: InputEvent) => browserCall<{ ok: true }>(chat, "input", event);
export const browserHover = (chat: string, x: number, y: number) => browserCall<HoverHit | null>(chat, "hover", { x, y });
export const browserInspect = (chat: string, x: number, y: number) => browserCall<InspectHit | null>(chat, "inspect", { x, y });
export const browserHighlight = (chat: string, target: { ref: string } | { selector: string }) =>
  browserCall<{ ok: true }>(chat, "highlight", target);
export const browserMap = (chat: string) => browserCall<ElementMap | null>(chat, "map");
export const browserHandle = (chat: string) => browserCall<KuriHandle | null>(chat, "handle");
export const browserClose = (chat: string) => browserCall<{ ok: true }>(chat, "close");
export const browserStop = (chat: string) => browserCall<{ kuri: KuriState }>(chat, "stop");

/** The same methods against the user's own Chrome, via the paired
 * extension instead of the sidecar. `open` creates a tab in the user's
 * window; the chat's later calls default to that tab, else the active one. */
export async function extensionStatusRead(): Promise<ExtensionStatus> {
  const res = await fetch("/api/extension", { cache: "no-store" });
  if (res.status === 401) return { paired: false, lastPollMs: null, tabs: [], pendingPins: 0 };
  if (!res.ok) throw new Error(`extension status → ${res.status}`);
  return (await res.json()) as ExtensionStatus;
}
export const extensionTabs = (chat: string) => extensionCall<ExtensionTab[]>(chat, "tabs");
export const extensionSnapshot = (chat: string) => extensionCall<{ snapshot: string; url: string; title: string }>(chat, "snapshot");
export const extensionClick = (chat: string, target: { ref: string } | { selector: string }) => extensionCall<{ ok: true }>(chat, "click", target);
export const extensionFill = (chat: string, target: ({ ref: string } | { selector: string }) & { text: string }) =>
  extensionCall<{ ok: true }>(chat, "fill", target);
export const extensionHighlight = (chat: string, target: { ref: string } | { selector: string }) =>
  extensionCall<{ ok: true }>(chat, "highlight", target);
export const extensionNavigate = (chat: string, url: string) => extensionCall<{ ok: true }>(chat, "navigate", { url });
