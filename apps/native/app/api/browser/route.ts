import { NextRequest } from "next/server";
import { matchRef, parseSnapshotRefs, type PinElement } from "@/lib/browser/annotations";
import { hoverExpression, inspectExpression, mapExpression, scrollExpression } from "@/lib/browser/inspect-script";
import { ensureKuri, kuriAddress, kuriJson, kuriState, q, stopKuri } from "@/lib/browser/kuri-supervisor";
import { normalizeUrl } from "@/lib/browser/url";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

/** The sidecar browser: one Kuri (and its headless Chrome) per dev server,
 * one Chrome tab per chat. `GET ?frame=1` is the live picture the pane
 * polls; `POST {chat, method, params}` drives the tab and identifies the
 * element under a point for annotations. Only `open` spawns the browser —
 * status and frames never do, so a closed pane stays free. */

/** `url` is the last address the tab was known to show: if Kuri dies, the
 * chat's tab is recreated there on the next request. */
type Tab = { id: string; width: number; height: number; url?: string };

const g = globalThis as typeof globalThis & {
  __graffBrowserTabs?: Map<string, Tab>;
  __graffBrowserChains?: Map<string, Promise<void>>;
};
const tabs = (g.__graffBrowserTabs ??= new Map<string, Tab>());
const chains = (g.__graffBrowserChains ??= new Map<string, Promise<void>>());

/** One request at a time per chat. Kuri handles each HTTP connection on
 * its own thread, and two of them driving the same tab's CDP client at
 * once (a frame and an element map, say) segfaulted it in
 * `CdpClient.send`. Different chats, different tabs, still overlap. */
function serial<T>(key: string, fn: () => Promise<T>): Promise<T> {
  const prev = chains.get(key) ?? Promise.resolve();
  const run = prev.catch(() => undefined).then(fn);
  const settled: Promise<void> = run.then(
    () => undefined,
    () => undefined,
  );
  chains.set(key, settled);
  void settled.then(() => {
    if (chains.get(key) === settled) chains.delete(key);
  });
  return run;
}
const DEFAULT_CHAT = "default";
const DEFAULT_SIZE = { width: 960, height: 640 };

type PageInfo = { tabId: string; url: string; title: string; width: number; height: number; ready: string };

type KuriPageInfo = {
  url?: string;
  title?: string;
  viewport_width?: number;
  viewport_height?: number;
  ready_state?: string;
};

async function setViewport(id: string, size: { width: number; height: number }): Promise<void> {
  await kuriJson(`/set/viewport${q({ tab_id: id, width: size.width, height: size.height })}`);
}

async function tabAlive(id: string): Promise<boolean> {
  const list = await kuriJson<{ id: string }[]>("/tabs");
  return Array.isArray(list) && list.some((t) => t.id === id);
}

async function ensureTab(chat: string, size?: { width: number; height: number }): Promise<Tab> {
  await ensureKuri();
  const have = tabs.get(chat);
  if (have && (await tabAlive(have.id))) {
    if (size && (size.width !== have.width || size.height !== have.height)) {
      await setViewport(have.id, size);
      have.width = size.width;
      have.height = size.height;
    }
    return have;
  }
  const created = await kuriJson<{ tab_id?: string }>(`/tab/new${q({ url: "about:blank", wait: "true" })}`);
  if (!created.tab_id) throw new Error("kuri /tab/new returned no tab_id");
  const tab: Tab = { id: created.tab_id, ...(size ?? DEFAULT_SIZE) };
  await setViewport(tab.id, tab);
  tabs.set(chat, tab);
  return tab;
}

/** The chat's tab, brought back if Kuri (and the tab with it) went away:
 * a fresh Kuri, a fresh tab at the same size, back on the last address. */
async function reviveTab(chat: string): Promise<Tab | null> {
  const have = tabs.get(chat);
  if (!have) return null;
  if (kuriAddress() && (await tabAlive(have.id))) return have;
  const fresh = await ensureTab(chat, { width: have.width, height: have.height });
  if (have.url && have.url !== "about:blank") {
    await kuriJson(`/navigate${q({ tab_id: fresh.id, url: have.url })}`).catch(() => undefined);
    fresh.url = have.url;
  }
  return fresh;
}

async function pageInfo(tab: Tab): Promise<PageInfo> {
  const info = await kuriJson<KuriPageInfo>(`/page/info${q({ tab_id: tab.id })}`);
  if (info.url) tab.url = info.url;
  return {
    tabId: tab.id,
    url: info.url ?? "",
    title: info.title ?? "",
    width: info.viewport_width ?? tab.width,
    height: info.viewport_height ?? tab.height,
    ready: info.ready_state ?? "",
  };
}

async function evaluate<T>(tab: Tab, expression: string): Promise<T | null> {
  const body = await kuriJson<{ result?: { result?: { value?: unknown } } }>(`/evaluate${q({ tab_id: tab.id, expression })}`);
  const value = body.result?.result?.value;
  return value === undefined || value === null ? null : (value as T);
}

function size(params: Record<string, unknown> | undefined): { width: number; height: number } | undefined {
  const w = Number(params?.width);
  const h = Number(params?.height);
  if (!Number.isFinite(w) || !Number.isFinite(h) || w < 200 || h < 150) return undefined;
  return { width: Math.min(4000, Math.round(w)), height: Math.min(4000, Math.round(h)) };
}

function num(v: unknown, fallback = 0): number {
  const n = Number(v);
  return Number.isFinite(n) ? n : fallback;
}

export async function GET(req: NextRequest) {
  if (process.env.GRAFF_DESKTOP_ENDPOINT) return Response.json({ error: "Use the embedded Chromium browser" }, { status: 410 });
  const chat = req.nextUrl.searchParams.get("chat") || DEFAULT_CHAT;
  const tab = tabs.get(chat) ?? null;
  const live = kuriAddress();
  if (req.nextUrl.searchParams.get("frame")) {
    if (!live || !tab) return Response.json({ error: "no browser tab for this chat" }, { status: 404 });
    const quality = Math.min(95, Math.max(20, num(req.nextUrl.searchParams.get("q"), 55)));
    try {
      const shot = await serial(chat, () =>
        kuriJson<{ result?: { data?: string } }>(`/screenshot${q({ tab_id: tab.id, format: "jpeg", quality })}`),
      );
      const data = shot.result?.data;
      if (!data) return Response.json({ error: "no frame" }, { status: 502 });
      return new Response(new Uint8Array(Buffer.from(data, "base64")), {
        headers: { "content-type": "image/jpeg", "cache-control": "no-store" },
      });
    } catch (err) {
      return Response.json({ error: err instanceof Error ? err.message : String(err) }, { status: 502 });
    }
  }
  let page: PageInfo | null = null;
  if (live && tab) {
    try {
      page = await pageInfo(tab);
    } catch {
      page = null;
    }
  }
  return Response.json({ kuri: kuriState(), tab: page });
}

export async function POST(req: NextRequest) {
  if (process.env.GRAFF_DESKTOP_ENDPOINT) return Response.json({ error: "Use the embedded Chromium browser" }, { status: 410 });
  const body = (await req.json()) as { chat?: string; method?: string; params?: Record<string, unknown> };
  const chat = typeof body.chat === "string" && body.chat ? body.chat : DEFAULT_CHAT;
  const method = body.method ?? "";
  const params = body.params ?? {};
  return serial(chat, () => handle(chat, method, params));
}

async function handle(chat: string, method: string, params: Record<string, unknown>): Promise<Response> {
  try {
    if (method === "warm") {
      await ensureKuri();
      return Response.json({ kuri: kuriState() });
    }
    if (method === "stop") {
      tabs.clear();
      stopKuri();
      return Response.json({ kuri: kuriState() });
    }
    if (method === "close") {
      const tab = tabs.get(chat);
      tabs.delete(chat);
      if (tab && kuriAddress()) await kuriJson(`/tab/close${q({ tab_id: tab.id })}`).catch(() => undefined);
      return Response.json({ ok: true });
    }
    if (method === "handle") {
      const live = kuriAddress();
      const tab = tabs.get(chat);
      return Response.json(live && tab ? { port: live.port, token: live.token, tabId: tab.id } : null);
    }
    if (method === "open") {
      const tab = await ensureTab(chat, size(params));
      if (typeof params.url === "string" && params.url.trim()) {
        await kuriJson(`/navigate${q({ tab_id: tab.id, url: normalizeUrl(params.url) })}`);
      }
      return Response.json(await pageInfo(tab));
    }
    // Everything below drives a tab that must already exist; a pane that
    // was never opened has nothing to drive and must not spawn a browser.
    // One that was opened and lost its Kuri gets it back here.
    const tab = await reviveTab(chat);
    if (!tab) return Response.json({ error: "open the browser first" }, { status: 409 });
    switch (method) {
      case "navigate": {
        await kuriJson(`/navigate${q({ tab_id: tab.id, url: normalizeUrl(String(params.url ?? "")) })}`);
        return Response.json(await pageInfo(tab));
      }
      case "back":
      case "forward":
      case "reload": {
        await kuriJson(`/${method}${q({ tab_id: tab.id })}`);
        return Response.json(await pageInfo(tab));
      }
      case "info":
        return Response.json(await pageInfo(tab));
      case "viewport": {
        const s = size(params);
        if (s) {
          await setViewport(tab.id, s);
          tab.width = s.width;
          tab.height = s.height;
        }
        return Response.json({ width: tab.width, height: tab.height });
      }
      case "input": {
        const x = Math.round(num(params.x));
        const y = Math.round(num(params.y));
        const button = typeof params.button === "string" ? params.button : "left";
        switch (params.kind) {
          case "move":
            await kuriJson(`/mouse/move${q({ tab_id: tab.id, x, y })}`);
            break;
          case "down":
            await kuriJson(`/mouse/down${q({ tab_id: tab.id, x, y, button })}`);
            break;
          case "up":
            await kuriJson(`/mouse/up${q({ tab_id: tab.id, x, y, button })}`);
            break;
          case "click":
            await kuriJson(`/mouse/move${q({ tab_id: tab.id, x, y })}`);
            await kuriJson(`/mouse/down${q({ tab_id: tab.id, x, y, button })}`);
            await kuriJson(`/mouse/up${q({ tab_id: tab.id, x, y, button })}`);
            break;
          case "wheel":
            // Not /mouse/wheel: see scrollExpression.
            await evaluate<string>(tab, scrollExpression(x, y, num(params.deltaX), num(params.deltaY)));
            break;
          case "key": {
            const key = String(params.key ?? "");
            if (!key) break;
            await kuriJson(`/keydown${q({ tab_id: tab.id, key })}`);
            await kuriJson(`/keyup${q({ tab_id: tab.id, key })}`);
            break;
          }
          case "type": {
            const text = String(params.text ?? "");
            if (text) await kuriJson(`/keyboard/type${q({ tab_id: tab.id, text })}`);
            break;
          }
          default:
            return Response.json({ error: `unknown input kind: ${String(params.kind)}` }, { status: 400 });
        }
        return Response.json({ ok: true });
      }
      case "hover": {
        const hit = await evaluate<{ rect: PinElement["rect"]; tag: string }>(tab, hoverExpression(num(params.x), num(params.y)));
        return Response.json(hit);
      }
      case "inspect": {
        const hit = await evaluate<PinElement & { url: string; title: string }>(tab, inspectExpression(num(params.x), num(params.y)));
        if (!hit) return Response.json(null);
        let ref: string | null = null;
        try {
          const snapshot = await kuriJson<string>(`/snapshot${q({ tab_id: tab.id, filter: "interactive", format: "compact" })}`);
          if (typeof snapshot === "string") ref = matchRef(parseSnapshotRefs(snapshot), hit);
        } catch {
          // a page mid-navigation has no snapshot; the pin still stands
        }
        const { url, title, ...element } = hit;
        return Response.json({ element, ref, url, title });
      }
      case "snapshot": {
        const snapshot = await kuriJson<string>(`/snapshot${q({ tab_id: tab.id, filter: "interactive", format: "compact" })}`);
        return Response.json({ snapshot: typeof snapshot === "string" ? snapshot : JSON.stringify(snapshot) });
      }
      case "map": {
        // Everything pinnable on screen, each with Kuri's ref when the
        // accessibility snapshot names the same element. One evaluate plus
        // one snapshot; the pane hit-tests the result locally.
        type MapEl = PinElement & { i: number };
        type Map = { url: string; title: string; vw: number; vh: number; scrollX: number; scrollY: number; els: MapEl[] };
        const map = await evaluate<Map>(tab, mapExpression());
        if (!map) return Response.json(null);
        let rows: ReturnType<typeof parseSnapshotRefs> = [];
        try {
          const snapshot = await kuriJson<string>(`/snapshot${q({ tab_id: tab.id, filter: "interactive", format: "compact" })}`);
          if (typeof snapshot === "string") rows = parseSnapshotRefs(snapshot);
        } catch {
          // mid-navigation: no refs this round
        }
        const els = map.els.map((el) => ({ ...el, ref: el.role ? matchRef(rows, el) : null }));
        return Response.json({ ...map, els });
      }
      case "highlight": {
        const target = typeof params.ref === "string" ? { ref: params.ref } : { selector: String(params.selector ?? "") };
        await kuriJson(`/highlight${q({ tab_id: tab.id, ...target })}`);
        return Response.json({ ok: true });
      }
      default:
        return Response.json({ error: `unknown method: ${method}` }, { status: 400 });
    }
  } catch (err) {
    return Response.json({ error: err instanceof Error ? err.message : String(err) }, { status: 502 });
  }
}
