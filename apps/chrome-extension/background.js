/** Graff Sidecar — background service worker (MV3).
 *
 * Outbound-only: long-polls the harness for commands, executes them against
 * tabs / page content, POSTs results back. There is no listening socket; the
 * worst a wrong token gets is a 401. Loopback only — the URL must be
 * http(s)://127.0.0.1 or localhost, enforced before every request.
 *
 * Protocol (see apps/native/lib/extension-bridge.ts for the harness side):
 *   POST /api/extension  { type: "poll", extId, tabs: [...] } -> { command }
 *   POST /api/extension  { type: "result", id, ok, result?, error? }
 *   POST /api/extension  { type: "event", event: "pin"|"tabs", ... }
 * Auth: `Authorization: Bearer <token>` on every call.
 */

const RETRY_MS = 3000;

function extId() {
  return chrome.runtime.id;
}

async function config() {
  const { harnessUrl, token } = await chrome.storage.local.get(["harnessUrl", "token"]);
  return {
    harnessUrl: String(harnessUrl || "http://127.0.0.1:3000").replace(/\/+$/, ""),
    token: String(token || ""),
  };
}

/** Refuse anything that is not this machine. */
function loopbackOnly(url) {
  let u;
  try {
    u = new URL(url);
  } catch {
    throw new Error("Harness URL is not a URL");
  }
  if (!["http:", "https:"].includes(u.protocol)) throw new Error("Harness URL must be http(s)");
  if (!["127.0.0.1", "localhost", "[::1]"].includes(u.hostname)) throw new Error("Harness URL must be loopback");
  return u.origin;
}

async function api(path, body) {
  const { harnessUrl, token } = await config();
  if (!token) throw new Error("Not paired: open the popup and enter the pairing token");
  const origin = loopbackOnly(harnessUrl);
  const res = await fetch(`${origin}${path}`, {
    method: "POST",
    headers: { "content-type": "application/json", authorization: `Bearer ${token}` },
    body: JSON.stringify(body),
    cache: "no-store",
  });
  if (res.status === 401) throw new Error("Pairing token rejected — re-pair in the popup");
  if (!res.ok) throw new Error(`Harness ${res.status}`);
  return res.json();
}

async function listTabs() {
  const tabs = await chrome.tabs.query({});
  return tabs.map((t) => ({ id: t.id, windowId: t.windowId, url: t.url || "", title: t.title || "", active: !!t.active }));
}

async function resolveTab(ref) {
  if (ref === "active" || ref === undefined || ref === null) {
    const [t] = await chrome.tabs.query({ active: true, lastFocusedWindow: true });
    if (!t?.id) throw new Error("No active tab");
    return t;
  }
  const t = await chrome.tabs.get(Number(ref)).catch(() => null);
  if (!t?.id) throw new Error(`Tab ${ref} is gone`);
  return t;
}

/** Ask the tab's content script; inject it first on pages the manifest
 * did not cover (e.g. tabs opened before install). chrome:// pages throw. */
async function ask(tabId, cmd, params = {}) {
  try {
    return await chrome.tabs.sendMessage(tabId, { cmd, params });
  } catch {
    await chrome.scripting.executeScript({ target: { tabId }, files: ["content.js"] });
    return await chrome.tabs.sendMessage(tabId, { cmd, params });
  }
}

/** Page-level methods run in the content script; tab-level ones here. */
async function execute(command) {
  const { method, params = {}, tab: tabRef } = command;
  switch (method) {
    case "tabs":
      return listTabs();
    case "info": {
      const t = await resolveTab(tabRef);
      return { id: t.id, url: t.url || "", title: t.title || "", active: t.active };
    }
    case "navigate": {
      const t = await resolveTab(tabRef);
      await chrome.tabs.update(t.id, { url: String(params.url) });
      return { ok: true };
    }
    case "back":
      return ask((await resolveTab(tabRef)).id, "history", { go: -1 });
    case "forward":
      return ask((await resolveTab(tabRef)).id, "history", { go: 1 });
    case "reload":
      await chrome.tabs.reload((await resolveTab(tabRef)).id);
      return { ok: true };
    case "zoom": {
      const t = await resolveTab(tabRef);
      if (params.factor !== undefined) await chrome.tabs.setZoom(t.id, Number(params.factor));
      return { factor: await chrome.tabs.getZoom(t.id) };
    }
    case "screenshot": {
      const t = await resolveTab(tabRef);
      return { data: await chrome.tabs.captureVisibleTab(t.windowId, { format: "jpeg", quality: 70 }) };
    }
    case "snapshot":
    case "map":
    case "inspect":
    case "evaluate":
    case "click":
    case "fill":
    case "select":
    case "scroll":
    case "highlight":
    case "pick":
    case "pins":
      return ask((await resolveTab(tabRef)).id, method, params);
    default:
      throw new Error(`Unknown method: ${method}`);
  }
}

let polling = false;

/** One long-poll round trip: report tabs, run at most one command, post
 * the result. Errors resolve to a retry, never a throw — the loop is the
 * extension's heartbeat and must not die. */
async function round() {
  const tabs = await listTabs().catch(() => []);
  const { command } = await api("/api/extension", { type: "poll", extId: extId(), tabs });
  if (!command) return;
  let ok = true, result = null, error = "";
  try {
    result = await execute(command);
  } catch (err) {
    ok = false;
    error = err instanceof Error ? err.message : String(err);
  }
  await api("/api/extension", { type: "result", id: command.id, ok, result, error }).catch(() => undefined);
}

async function loop() {
  if (polling) return;
  polling = true;
  try {
    for (;;) {
      const { token } = await config();
      if (!token) return; // unpaired: rest until the popup saves a token
      try {
        await round();
      } catch {
        await new Promise((r) => setTimeout(r, RETRY_MS));
      }
      await chrome.storage.local.set({ lastPollMs: Date.now() }).catch(() => undefined);
    }
  } finally {
    polling = false;
  }
}

chrome.runtime.onStartup.addListener(() => void loop());
chrome.runtime.onInstalled.addListener(() => void loop());
chrome.alarms.create("heartbeat", { periodInMinutes: 1 });
chrome.alarms.onAlarm.addListener(() => void loop());
// The popup and content scripts wake the loop after pairing / pinning.
chrome.runtime.onMessage.addListener((msg) => {
  if (msg?.cmd === "wake") void loop();
  if (msg?.cmd === "pin-event") {
    void api("/api/extension", { type: "event", event: "pin", pin: msg.pin }).catch(() => undefined);
  }
});
void loop();
