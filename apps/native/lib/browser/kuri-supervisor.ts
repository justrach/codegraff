import { spawn, spawnSync, type ChildProcess } from "node:child_process";
import { randomBytes } from "node:crypto";
import { existsSync, mkdirSync } from "node:fs";
import net from "node:net";
import os from "node:os";
import path from "node:path";

/** The sidecar's browser is Kuri's managed Chrome (headless, its own profile
 * under ~/.codegraff/browser). Nothing runs until the first request needs
 * it; a quiet spell stops it again, so a closed pane costs no processes.
 * One Kuri per dev server, kept on globalThis so module reloads do not
 * orphan a Chrome. Kuri kills its Chrome when it is stopped. */

export type KuriState = {
  running: boolean;
  port: number | null;
  pid: number | null;
  startedMs: number | null;
  lastUsedMs: number | null;
  bin: string | null;
  idleMs: number;
  /** Last measured RSS of Kuri and its Chrome tree (MB), and the cap. */
  rssMb: number | null;
  maxRssMb: number;
};

type Live = {
  child: ChildProcess;
  port: number;
  token: string;
  startedMs: number;
  lastUsedMs: number;
  idleTimer: NodeJS.Timeout | null;
  rssTimer: NodeJS.Timeout | null;
  /** Last measured RSS of Kuri and its Chrome tree, MB. */
  rssMb: number | null;
  ready: Promise<void>;
};

type State = { live: Live | null; hooked: boolean; spawning: Promise<{ port: number; token: string }> | null };
const g = globalThis as typeof globalThis & { __graffKuri?: State };
const state: State = (g.__graffKuri ??= { live: null, hooked: false, spawning: null });

const FIRST_PORT = 8091;
// Kuri answers /health only once its Chrome is up, and a launch that hits
// a stale profile lock retries three times at fifteen seconds each.
const HEALTH_TIMEOUT_MS = 75_000;

/** `KURI_BIN`, the installer's `~/.local/bin/kuri`, a source build, then PATH. */
export function kuriBin(): string | null {
  const home = os.homedir();
  const named = [process.env.KURI_BIN, path.join(home, ".local/bin/kuri"), path.join(home, "kuri/zig-out/bin/kuri")];
  for (const candidate of named) if (candidate && existsSync(candidate)) return candidate;
  for (const dir of (process.env.PATH ?? "").split(path.delimiter)) {
    if (!dir) continue;
    const candidate = path.join(dir, "kuri");
    if (existsSync(candidate)) return candidate;
  }
  return null;
}

/** Minutes of silence before the browser is stopped; 0 keeps it forever. */
export function idleMs(): number {
  const raw = process.env.GRAFF_BROWSER_IDLE_MINS;
  const mins = raw === undefined || raw === "" ? 20 : Number(raw);
  if (!Number.isFinite(mins) || mins < 0) return 20 * 60_000;
  return Math.min(mins, 7 * 24 * 60) * 60_000;
}

/** Resident memory (MB) the sidecar, Kuri plus its whole Chrome tree, may use
 * before it is stopped; the next request starts a fresh, small one. A headless
 * Chrome with a couple of tabs sits around 1.5 GB, so the default leaves room
 * for a heavy page without letting a leak run away. 0 disables the cap. */
export function maxRssMb(): number {
  const raw = process.env.GRAFF_BROWSER_MAX_RSS_MB;
  const mb = raw === undefined || raw === "" ? 3072 : Number(raw);
  if (!Number.isFinite(mb) || mb < 0) return 3072;
  return mb;
}

/** RSS of a process and everything under it, in MB; 0 where `ps` cannot say. */
export function treeRssMb(rootPid: number): number {
  if (process.platform === "win32") return 0;
  let out: ReturnType<typeof spawnSync>;
  try {
    out = spawnSync("ps", ["-axo", "pid=,ppid=,rss="], { encoding: "utf8", timeout: 2_000 });
  } catch {
    return 0;
  }
  if (out.status !== 0 || typeof out.stdout !== "string") return 0;
  const children = new Map<number, number[]>();
  const rss = new Map<number, number>();
  for (const line of out.stdout.split("\n")) {
    const [pid, ppid, kb] = line.trim().split(/\s+/).map(Number);
    if (!pid) continue;
    rss.set(pid, kb || 0);
    const list = children.get(ppid);
    if (list) list.push(pid);
    else children.set(ppid, [pid]);
  }
  let total = 0;
  const stack = [rootPid];
  while (stack.length) {
    const pid = stack.pop() as number;
    total += rss.get(pid) ?? 0;
    for (const child of children.get(pid) ?? []) stack.push(child);
  }
  return Math.round(total / 1024);
}

const RSS_CHECK_MS = 30_000;

/** Watch the sidecar's footprint while it runs and stop it past the cap. */
function armRssGuard(live: Live): void {
  const cap = maxRssMb();
  if (cap === 0 || !live.child.pid) return;
  const pid = live.child.pid;
  live.rssTimer = setInterval(() => {
    if (state.live !== live || live.child.exitCode !== null) {
      if (live.rssTimer) clearInterval(live.rssTimer);
      return;
    }
    const mb = treeRssMb(pid);
    live.rssMb = mb;
    if (mb > cap) {
      console.error(`[browser] the sidecar browser is using ${mb} MB (cap ${cap} MB, GRAFF_BROWSER_MAX_RSS_MB): stopping it; the next request starts a fresh one`);
      stopKuri();
    }
  }, RSS_CHECK_MS);
  live.rssTimer.unref();
}

function portFree(port: number): Promise<boolean> {
  return new Promise((resolve) => {
    const probe = net.createServer();
    probe.once("error", () => resolve(false));
    probe.listen(port, "127.0.0.1", () => probe.close(() => resolve(true)));
  });
}

async function freePort(): Promise<number> {
  for (let port = FIRST_PORT; port < FIRST_PORT + 60; port += 1) {
    if (await portFree(port)) return port;
  }
  throw new Error("no free port for the sidecar browser");
}

async function waitHealthy(port: number, token: string, child: ChildProcess): Promise<void> {
  const deadline = Date.now() + HEALTH_TIMEOUT_MS;
  while (Date.now() < deadline) {
    if (child.exitCode !== null) throw new Error(`kuri exited with code ${child.exitCode} before it was healthy`);
    try {
      const res = await fetch(`http://127.0.0.1:${port}/health`, {
        headers: { authorization: `Bearer ${token}` },
        cache: "no-store",
      });
      if (res.ok) return;
    } catch {
      // not listening yet
    }
    await new Promise((r) => setTimeout(r, 250));
  }
  throw new Error("kuri did not become healthy in time");
}

function armIdle(live: Live): void {
  if (live.idleTimer) clearTimeout(live.idleTimer);
  const ms = idleMs();
  if (ms === 0) return;
  live.idleTimer = setTimeout(() => {
    const quiet = Date.now() - live.lastUsedMs;
    if (quiet >= ms) {
      if (state.live === live) stopKuri();
    } else {
      armIdle(live);
    }
  }, Math.max(1_000, ms - (Date.now() - live.lastUsedMs)));
  live.idleTimer.unref();
}

function hookExit(): void {
  if (state.hooked) return;
  state.hooked = true;
  process.once("exit", () => stopKuri());
}

const STATE_DIR = path.join(os.homedir(), ".codegraff", "browser");
const PRIVATE_HOME = path.join(STATE_DIR, "home");
/** Every Chrome the sidecar's Kuri launches carries this in its argv. */
const PROFILE_MARK = path.join(PRIVATE_HOME, ".kuri", "chrome-profile");

/** Chrome renderers that outlived their Kuri (the dev server died before
 * Kuri could wind them down) hold the profile's lock and stall the next
 * launch by a minute. The profile is private to the sidecar, so killing
 * whatever still runs on it is safe. Synchronous: this also runs from the
 * process's exit handler, where nothing asynchronous gets a turn. */
function reapProfileChrome(): void {
  if (process.platform === "win32") return;
  try {
    spawnSync("pkill", ["-f", PROFILE_MARK], { stdio: "ignore", timeout: 2_000 });
  } catch {
    // pkill missing or no match
  }
}

/** The live Kuri, spawning it when there is none. Two chats asking at once
 * (both panes open on a dead browser) share one spawn. */
export async function ensureKuri(): Promise<{ port: number; token: string }> {
  const live = state.live;
  if (live && live.child.exitCode === null) {
    live.lastUsedMs = Date.now();
    await live.ready;
    return { port: live.port, token: live.token };
  }
  if (state.spawning) return state.spawning;
  const spawning = spawnKuri();
  state.spawning = spawning;
  try {
    return await spawning;
  } finally {
    if (state.spawning === spawning) state.spawning = null;
  }
}

async function spawnKuri(): Promise<{ port: number; token: string }> {
  const bin = kuriBin();
  if (!bin) {
    throw new Error(
      "kuri is not installed: run `curl -fsSL https://kuri.trilok.ai/download | sh` or set KURI_BIN to the binary",
    );
  }
  const port = await freePort();
  const token = randomBytes(16).toString("hex");
  // Kuri keeps its Chrome profile at $HOME/.kuri/chrome-profile-headless,
  // one per user, and two Chromes cannot share a profile: a `kuri` the
  // user runs for other agents would lock ours out (and the other way
  // round). A private HOME gives the sidecar its own profile and state.
  mkdirSync(PRIVATE_HOME, { recursive: true });
  reapProfileChrome();
  const child = spawn(bin, [], {
    env: {
      ...process.env,
      HOME: PRIVATE_HOME,
      HOST: "127.0.0.1",
      PORT: String(port),
      HEADLESS: "true",
      STATE_DIR: path.join(STATE_DIR, "state"),
      KURI_API_TOKEN: token,
      KURI_NO_TELEMETRY: "1",
      // The pane exists to look at dev servers on this machine; Kuri blocks
      // localhost/private targets by default (SSRF guard for its crawler).
      KURI_ALLOW_LOCAL: "1",
    },
    // Kuri's own log goes to the dev server's terminal like the agents' do.
    stdio: ["ignore", "ignore", "inherit"],
  });
  const next: Live = {
    child,
    port,
    token,
    startedMs: Date.now(),
    lastUsedMs: Date.now(),
    idleTimer: null,
    rssTimer: null,
    rssMb: null,
    ready: Promise.resolve(),
  };
  next.ready = waitHealthy(port, token, child);
  child.on("exit", (code, signal) => {
    const mine = state.live === next;
    if (mine) state.live = null;
    if (next.idleTimer) clearTimeout(next.idleTimer);
    if (next.rssTimer) clearInterval(next.rssTimer);
    // A Kuri that died on its own (not our stop) leaves its Chrome behind.
    if (mine) {
      console.error(`[browser] kuri exited unexpectedly (code=${code ?? "?"} signal=${signal ?? "none"}); the next request respawns it`);
      reapProfileChrome();
    }
  });
  state.live = next;
  hookExit();
  armIdle(next);
  armRssGuard(next);
  try {
    await next.ready;
  } catch (err) {
    stopKuri();
    throw err;
  }
  return { port, token };
}

export function touchKuri(): void {
  if (state.live) state.live.lastUsedMs = Date.now();
}

/** SIGTERM, then SIGKILL if it lingers. Kuri takes its Chrome down with it
 * when it gets the chance; the profile reap covers the times it does not. */
export function stopKuri(): void {
  const live = state.live;
  if (!live) return;
  state.live = null;
  if (live.idleTimer) clearTimeout(live.idleTimer);
  if (live.rssTimer) clearInterval(live.rssTimer);
  try {
    live.child.kill("SIGTERM");
  } catch {
    // already gone
  }
  const hard = setTimeout(() => {
    if (live.child.exitCode === null) {
      try {
        live.child.kill("SIGKILL");
      } catch {
        // already gone
      }
    }
    reapProfileChrome();
  }, 3_000);
  hard.unref();
  // The exit handler gets no timers: reap now as well, so a dev server
  // that dies takes the sidecar's Chrome with it.
  reapProfileChrome();
}

export function kuriState(): KuriState {
  const live = state.live && state.live.child.exitCode === null ? state.live : null;
  return {
    running: live !== null,
    port: live?.port ?? null,
    pid: live?.child.pid ?? null,
    startedMs: live?.startedMs ?? null,
    lastUsedMs: live?.lastUsedMs ?? null,
    bin: kuriBin(),
    idleMs: idleMs(),
    rssMb: live?.rssMb ?? null,
    maxRssMb: maxRssMb(),
  };
}

/** The live Kuri's address for a caller that wants to drive the same
 * browser itself (the agent, over curl); null when nothing is running. */
export function kuriAddress(): { port: number; token: string } | null {
  const live = state.live && state.live.child.exitCode === null ? state.live : null;
  return live ? { port: live.port, token: live.token } : null;
}

/** One Kuri HTTP call; spawns the browser on first use. */
export async function kuri(pathAndQuery: string, init?: RequestInit): Promise<Response> {
  const { port, token } = await ensureKuri();
  touchKuri();
  return fetch(`http://127.0.0.1:${port}${pathAndQuery}`, {
    ...init,
    headers: { authorization: `Bearer ${token}`, ...(init?.headers ?? {}) },
    cache: "no-store",
  });
}

export async function kuriJson<T = Record<string, unknown>>(pathAndQuery: string, init?: RequestInit): Promise<T> {
  const res = await kuri(pathAndQuery, init);
  const text = await res.text();
  let body: unknown;
  try {
    body = JSON.parse(text);
  } catch {
    if (!res.ok) throw new Error(`kuri ${res.status}: ${text.slice(0, 200)}`);
    return text as unknown as T;
  }
  const rec = body as { error?: unknown };
  if (!res.ok || (rec && typeof rec === "object" && typeof rec.error === "string")) {
    throw new Error(typeof rec.error === "string" ? rec.error : `kuri ${res.status}`);
  }
  return body as T;
}

export function q(params: Record<string, string | number | boolean | undefined>): string {
  const u = new URLSearchParams();
  for (const [k, v] of Object.entries(params)) if (v !== undefined) u.set(k, String(v));
  const s = u.toString();
  return s ? `?${s}` : "";
}
