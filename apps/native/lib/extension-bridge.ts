/** Harness side of the Graff Sidecar Chrome extension.
 *
 * The extension phones out: it long-polls POST /api/extension for commands
 * and POSTs results back, authenticated by a pairing token (Bearer). The
 * harness never listens for the extension and never holds its pages —
 * pairing is an explicit user gesture in the extension popup, loopback
 * only, either side unpaired at any time.
 *
 * Method names mirror POST /api/browser where they overlap (tabs, info,
 * navigate, snapshot, click, fill, highlight, …) so agent code and the
 * annotations block treat a user tab like a sidecar tab. One deliberate
 * difference: `open` creates a real tab in the user's window, and
 * `screenshot` captures what the user sees — the user watches everything.
 */

import { randomBytes, timingSafeEqual } from "node:crypto";
import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import os from "node:os";
import path from "node:path";

import type { BrowserPin } from "./browser/annotations.ts";
export { extensionAnnotationsBlock } from "./extension-annotations.ts";

export type ExtensionTab = { id: number; windowId: number; url: string; title: string; active: boolean };

export type ExtensionCommand = { id: string; method: string; params: Record<string, unknown>; tab: number | "active" };

type Waiter = { resolve: (v: unknown) => void; reject: (e: Error) => void; timer: NodeJS.Timeout };

type BridgeState = {
  extId: string | null;
  lastPollMs: number | null;
  tabs: ExtensionTab[];
  queue: ExtensionCommand[];
  waiters: Map<string, Waiter>;
  pins: BrowserPin[];
  chatTabs: Map<string, number>;
};

const g = globalThis as typeof globalThis & { __graffExtension?: BridgeState };
const state: BridgeState = (g.__graffExtension ??= {
  extId: null,
  lastPollMs: null,
  tabs: [],
  queue: [],
  waiters: new Map(),
  pins: [],
  chatTabs: new Map(),
});

const TOKEN_FILE = path.join(os.homedir(), ".codegraff", "extension-token");
const COMMAND_TIMEOUT_MS = 60_000;
const MAX_PINS = 100;

/** The pairing token: `GRAFF_EXTENSION_TOKEN`, else a generated one kept
 * at 0600 in ~/.codegraff. Printed to the server log on first boot — that
 * log is where the user copies it into the extension popup. */
export function pairingToken(): string {
  const env = process.env.GRAFF_EXTENSION_TOKEN?.trim();
  if (env) return env;
  try {
    if (existsSync(TOKEN_FILE)) {
      const saved = readFileSync(TOKEN_FILE, "utf8").trim();
      if (saved) return saved;
    }
    const token = randomBytes(32).toString("hex");
    mkdirSync(path.dirname(TOKEN_FILE), { recursive: true, mode: 0o700 });
    writeFileSync(TOKEN_FILE, token + "\n", { mode: 0o600 });
    console.log(`[extension] pairing token (paste into the Graff Sidecar popup): ${token}`);
    return token;
  } catch {
    const token = randomBytes(32).toString("hex");
    console.log(`[extension] pairing token (paste into the Graff Sidecar popup): ${token}`);
    return token;
  }
}

export function checkBearer(actual: string | null): boolean {
  if (!actual) return false;
  const a = Buffer.from(actual);
  const b = Buffer.from(`Bearer ${pairingToken()}`);
  return a.length === b.length && timingSafeEqual(a, b);
}

export function extensionPaired(): boolean {
  return state.lastPollMs !== null && Date.now() - state.lastPollMs < 90_000;
}

export function extensionStatus(): { paired: boolean; lastPollMs: number | null; tabs: ExtensionTab[]; pendingPins: number } {
  return { paired: extensionPaired(), lastPollMs: state.lastPollMs, tabs: state.tabs, pendingPins: state.pins.length };
}

/** Latest poll from the extension: tabs now, plus at most one queued
 * command. Long-poll waits are done by the route, not here. */
export function extensionPoll(extId: string, tabs: ExtensionTab[]): ExtensionCommand | null {
  state.extId = extId;
  state.lastPollMs = Date.now();
  state.tabs = Array.isArray(tabs) ? tabs.slice(0, 200) : [];
  return state.queue.shift() ?? null;
}

export function extensionResult(id: string, ok: boolean, result: unknown, error: string): void {
  const waiter = state.waiters.get(id);
  if (!waiter) return;
  state.waiters.delete(id);
  clearTimeout(waiter.timer);
  if (ok) waiter.resolve(result);
  else waiter.reject(new Error(error || "extension command failed"));
}

export function extensionPin(pin: BrowserPin): void {
  if (!pin?.element) return;
  state.pins.push({ ...pin, id: typeof pin.id === "number" ? pin.id : Date.now() });
  if (state.pins.length > MAX_PINS) state.pins.splice(0, state.pins.length - MAX_PINS);
}

/** Pins the user made in their own tabs, drained by the prompt path. */
export function takeExtensionPins(): BrowserPin[] {
  return state.pins.splice(0, state.pins.length);
}

/** Which of the user's tabs a chat drives: pinned by `open`/`attach`,
 * else whatever tab is active. The user can always see it. */
export function attachChatTab(chat: string, tabId: number): void {
  state.chatTabs.set(chat, tabId);
}

function chatTab(chat: string): number | "active" {
  const id = state.chatTabs.get(chat);
  if (id !== undefined && state.tabs.some((t) => t.id === id)) return id;
  return "active";
}

/** Run one method in the user's Chrome. Resolves when the extension POSTs
 * the result; rejects when the tab is gone, the method is unknown, or the
 * extension is unpaired (nothing polls, nothing resolves). */
export function extensionCall<T>(chat: string, method: string, params: Record<string, unknown> = {}): Promise<T> {
  if (!extensionPaired()) return Promise.reject(new Error("Chrome extension is not paired — pair it from the Graff Sidecar popup"));
  const command: ExtensionCommand = { id: randomBytes(8).toString("hex"), method, params, tab: chatTab(chat) };
  return new Promise<T>((resolve, reject) => {
    const timer = setTimeout(() => {
      state.waiters.delete(command.id);
      reject(new Error(`extension ${method} timed out`));
    }, COMMAND_TIMEOUT_MS);
    timer.unref();
    state.waiters.set(command.id, { resolve: resolve as (v: unknown) => void, reject, timer });
    state.queue.push(command);
  });
}

