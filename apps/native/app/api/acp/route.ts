import { assertSessionWritable, closeSessionWriter, registerSessionWriter, sessionFile } from "@/lib/session-writers";
import { spawn, type ChildProcessByStdio } from "node:child_process";
import { existsSync, mkdirSync, writeFileSync } from "node:fs";
import os from "node:os";
import path from "node:path";
import type { Readable, Writable } from "node:stream";
import { NextRequest } from "next/server";
import type { AcpCommand } from "@/lib/acp";
import { AcpTransport } from "@/lib/acp-transport";
import { createPromptStream } from "@/lib/acp-prompt-stream";
import { defaultRoot, resolveRoot } from "@/lib/server-root";
import { prepareGuiPrompt } from "@/lib/gui-skill-context";
import { attachmentStore } from "@/lib/attachment-store";

import { retireWorker } from "@/lib/acp-retire";
import { rememberAnswer, validateAnswer } from "@/lib/ask-answer";
import { formatTermination, recordTermination, type TerminateReason } from "@/lib/acp-terminate";
import { bindSessionCwd, initializeWorker, serializeBootstrap } from "@/lib/acp-bootstrap";
import { finishCancelledPrompt } from "@/lib/acp-cancel";
import { armIdle, cancelIdle, forgetPark, forgetParkMatching, keepPark, parkNow, parkedChats, takeParked, type ParkedWorker } from "@/lib/acp-idle";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

type Slot = {
  // stderr is "inherit" (null here): the agent's diagnostics land in the dev
  // server's terminal instead of being buffered and lost.
  child: ChildProcessByStdio<Writable, Readable, null>;
  transport: AcpTransport;
  streaming: boolean;
  sessionId: string | null;
  model: string | null;
  /** graff session name (`--resume`): the file this agent autosaves to. */
  resume: string | null;
  /** The workspace the agent was spawned in: its cwd, where its sessions save. */
  cwd: string;
  yolo: boolean;
  /** Whether the configured MCP servers were started with it. */
  mcp: boolean;
  /** What the agent said it services, from `available_commands_update`. */
  commands: AcpCommand[];
  spawnError: Error | null;
  /** The in-flight session/prompt, kept so a cancel can end the turn gate. */
  pendingPrompt: Promise<unknown> | null;
  restart: boolean;
  restartReady: Promise<void> | null;
  /** Open session/idle SSE subscribers (peer pump). */
  idleListeners: number;
  /** `session/answer` call_ids already delivered to this worker. */
  answered: Set<string>;
  spawnedAt: number;
};

const HANDSHAKE_MS = 120_000;
const RPC_MS = 30_000;
/** How long a cancel waits for the interrupted turn to wind down on its own
 * before the streaming gate is forced open. Without this, a turn that never
 * sends a terminal reply (agent error, lost stream) 409s every follow-up. */
const CANCEL_GRACE_MS = 8_000;

type SpawnOpts = { model?: string; resume?: string; cwd: string; yolo: boolean; mcp: boolean };
type BootstrapOpts = { model?: string; reset?: boolean; resume?: string; cwd?: string; yolo?: boolean; mcp?: boolean };

/** An empty MCP config graff accepts as "no servers" (`GRAFF_MCP_CONFIG`):
 * every chat's agent otherwise starts every server in ~/.codegraff/mcp.json,
 * a gigabyte or more of processes per tab with a typical config. */
function mcpOffPath(): string {
  const file = path.join(os.homedir(), ".codegraff", "native", "mcp-off.json");
  if (!existsSync(file)) {
    mkdirSync(path.dirname(file), { recursive: true });
    writeFileSync(file, '{"mcpServers":{}}\n');
  }
  return file;
}

// One `graff acp` child per chat tab. The agent holds exactly one live
// session per process (`session/load` is not implemented), so a tab's
// conversation memory *is* its child: when every tab shared one child, each
// new tab respawned it and silently erased the others' context. Keys are the
// browser's `<page>:<chat>` handles, so a reloaded page never adopts a stale
// child's history; `dispose`/`dispose-page` reap children on tab close and
// page unload. Kept on globalThis so dev-server module reloads don't orphan
// running agents.
type BootstrapGeneration = { replacement?: Promise<Slot> };
const g = globalThis as typeof globalThis & { __graffAcpSlots?: Map<string, Slot>; __graffAcpBootstraps?: Map<string, Promise<Slot>>; __graffAcpBootstrapGenerations?: WeakMap<Promise<Slot>, BootstrapGeneration>; __graffAcpRetirements?: Map<string, Promise<void>>; __graffAcpShuttingDown?: boolean };
const slots = (g.__graffAcpSlots ??= new Map<string, Slot>());
const bootstraps = (g.__graffAcpBootstraps ??= new Map<string, Promise<Slot>>());
const bootstrapGenerations = (g.__graffAcpBootstrapGenerations ??= new WeakMap<Promise<Slot>, BootstrapGeneration>());
const retirements = (g.__graffAcpRetirements ??= new Map<string, Promise<void>>());
const DEFAULT_CHAT = "default";
// Session names become a CLI argument and a filename under .graff/sessions.
const SESSION_NAME_RE = /^[A-Za-z0-9][A-Za-z0-9._-]*$/;

function graffBin(): string {
  if (process.env.GRAFF_BIN) return process.env.GRAFF_BIN;
  const fromApp = path.resolve(process.cwd(), "../../zig-out/bin/graff");
  if (existsSync(fromApp)) return fromApp;
  const fromRoot = path.resolve(process.cwd(), "zig-out/bin/graff");
  if (existsSync(fromRoot)) return fromRoot;
  return "graff";
}

function defaultYolo(): boolean {
  const raw = process.env.GRAFF_YOLO;
  if (raw === "0" || raw === "false" || raw === "off" || raw === "no") return false;
  return true;
}

// A closed tab's agent gets stdin EOF first: `graff acp` leaves its read loop
// on EOF and writes the session's exit save on the way out, which a SIGTERM
// would skip. The signal is the fallback for an agent that does not wind down.
const EXIT_GRACE_MS = 5_000;

function parkSnapshot(slot: Slot): ParkedWorker {
  return { resume: slot.resume ?? slot.sessionId, model: slot.model, cwd: slot.cwd, yolo: slot.yolo, mcp: slot.mcp };
}

function slotBusy(slot: Slot): boolean {
  return slot.streaming || slot.pendingPrompt !== null || slot.idleListeners > 0;
}

function watchIdle(chat: string, slot: Slot): void {
  if (slotBusy(slot)) { cancelIdle(chat); return; }
  armIdle(chat, parkSnapshot(slot), () => { void killSlot(chat, true); }, () => {
    const live = slots.get(chat);
    return !live || live !== slot || slotBusy(live);
  });
}

function killSlot(chat: string, parkFlag?: unknown, reason: TerminateReason = "dispose"): Promise<void> {
  if (keepPark(parkFlag)) cancelIdle(chat);
  else forgetPark(chat);
  const slot = slots.get(chat);
  if (!slot) return retirements.get(chat) ?? Promise.resolve();
  const turnActive = slotBusy(slot);
  if (keepPark(parkFlag) && turnActive) return Promise.resolve();
  console.warn(formatTermination(recordTermination({
    chat,
    reason: keepPark(parkFlag) ? "idle-park" : reason,
    turnActive,
    childAgeMs: Date.now() - slot.spawnedAt,
    signal: "EOF",
  })));
  slots.delete(chat);
  try { slot.transport.abort(new Error("worker retired")); } catch { /* already closed */ }
  const pending = closeSessionWriter(slot.child, EXIT_GRACE_MS);
  retirements.set(chat, pending);
  const forget = () => { if (retirements.get(chat) === pending) retirements.delete(chat); };
  void pending.then(forget, forget);
  return pending;
}

async function killPage(page: string) {
  const prefix = `${page}:`;
  forgetParkMatching(prefix);
  const chats = [...new Set([...slots.keys(), ...retirements.keys(), ...parkedChats()])].filter(chat => chat.startsWith(prefix));
  await Promise.all(chats.map(chat => killSlot(chat, undefined, "dispose-page")));
}

function spawnAgent(chat: string, opts: SpawnOpts): Slot {
  if (opts.resume) assertSessionWritable(sessionFile(opts.cwd, opts.resume));
  const imageScope = path.dirname(sessionFile(opts.cwd, opts.resume ?? "pending"));
  attachmentStore().enrollSession(imageScope, process.pid);
  const args = ["acp"];
  if (opts.yolo) args.push("--yolo");
  if (opts.model) args.push("--model", opts.model);
  if (opts.resume) args.push("--resume", opts.resume);
  // Next's bundled server configuration is runtime-only. Leaking it into
  // agent shells makes unrelated Next projects skip their own configuration.
  const env = { ...process.env };
  delete env.__NEXT_PRIVATE_STANDALONE_CONFIG;
  const child = spawn(graffBin(), args, {
    stdio: ["pipe", "pipe", "inherit"],
    cwd: opts.cwd,
    // Inherited PWD is the Next host (apps/native). Graff's display cwd
    // falls back to PWD when Io realPath misses; pin it to the spawn root.
    env: { ...env, GRAFF_DESKTOP_CHAT: chat, GRAFF_CWD: opts.cwd, PWD: opts.cwd, ...(!opts.mcp ? { GRAFF_MCP_CONFIG: mcpOffPath() } : {}) },
  });
  const slot: Slot = {
    child,
    transport: null as unknown as AcpTransport,
    streaming: false,
    sessionId: null,
    model: opts.model ?? null,
    resume: opts.resume ?? null,
    cwd: opts.cwd,
    yolo: opts.yolo,
    mcp: opts.mcp,
    commands: [],
    spawnError: null,
    pendingPrompt: null,
    idleListeners: 0,
    restart: false,
    restartReady: null,
    answered: new Set<string>(),
    spawnedAt: Date.now(),
  };
  slot.transport = new AcpTransport(child, message => noteCommands(slot, message));
  child.on("error", (err) => {
    slot.spawnError = err;
  });
  child.on("exit", () => {
    if (slots.get(chat) !== slot || slot.restart) return;
    slots.delete(chat);
    parkNow(chat, parkSnapshot(slot));
  });
  slots.set(chat, slot);
  try { attachmentStore().enrollSession(imageScope, child.pid); }
  catch (error) { void killSlot(chat, undefined, "bootstrap-replace").catch(() => undefined); throw error; }
  if (slot.resume) registerSessionWriter(sessionFile(slot.cwd, slot.resume), child, () => {
    if (slots.get(chat) === slot) void killSlot(chat, undefined, "session-writer").catch(() => undefined);
  });
  return slot;
}

/** The agent advertises its command set once, unprompted, right after
 * session/new — so it has to be picked off the stream rather than asked for. */
function noteCommands(slot: Slot, msg: { params?: unknown }): void {
  const update = (msg.params as { update?: { sessionUpdate?: string; availableCommands?: AcpCommand[] } } | undefined)
    ?.update;
  if (update?.sessionUpdate !== "available_commands_update") return;
  if (Array.isArray(update.availableCommands)) slot.commands = update.availableCommands;
}

/** The advertisement follows the session/new result on the same stream, so
 * the reply to that call returns before it has been read. Wait briefly for
 * it rather than leaving the menu empty until the first prompt. */
async function drainCommands(slot: Slot): Promise<void> {
  const deadline = Date.now() + 2_000;
  while (!slot.commands.length && Date.now() < deadline) await new Promise(resolve => setTimeout(resolve, 10));
}
function rpc(slot: Slot, method: string, params?: unknown, timeoutMs = RPC_MS): Promise<unknown> {
  if (slot.streaming) return Promise.reject(new Error("A turn is active; retry this request after it finishes"));
  return slot.transport.request(method, params, timeoutMs);
}

/** Retire an unresponsive worker; bootstrap restores its saved session. */
async function endTurn(slot: Slot): Promise<void> {
  await finishCancelledPrompt(slot, async () => {
    slot.restart = true;
    slot.restartReady = retireWorker(slot.child);
    slot.transport.abort(new Error("The interrupted worker stopped responding; the next turn will reload its saved session."));
    await slot.restartReady;
  }, CANCEL_GRACE_MS);
}

/** The tab's live agent when it still matches what was asked for (model,
 * session file, workspace, approval mode); otherwise a fresh spawn. A
 * request that leaves a field out accepts whatever the live agent has. */
function matchesBootstrap(live: Slot, opts: BootstrapOpts): boolean {
  return (!opts.model || live.model === opts.model) &&
    (!opts.resume || live.resume === opts.resume) &&
    (!opts.cwd || live.cwd === opts.cwd) &&
    (opts.yolo === undefined || live.yolo === opts.yolo) &&
    (opts.mcp === undefined || live.mcp === opts.mcp);
}

function bootstrap(chat: string, opts: BootstrapOpts): Promise<Slot> {
  if (g.__graffAcpShuttingDown) return Promise.reject(new Error("Desktop is shutting down"));
  const live = slots.get(chat);
  // Explicit changes can replace a stalled handshake. Ordinary concurrent
  // requests must wait instead of killing the worker they are about to use.
  const replacing = opts.reset || (live !== undefined && !matchesBootstrap(live, opts));
  const previous = bootstraps.get(chat);
  const previousGeneration = previous ? bootstrapGenerations.get(previous) : undefined;
  // Every caller queued behind a handshake belongs to that same generation.
  // Replacing its tail must redirect the original caller as well as the queue.
  const generation: BootstrapGeneration = !replacing && previousGeneration ? previousGeneration : {};
  if (replacing) bootstraps.delete(chat);
  const serialized = serializeBootstrap(bootstraps, chat, () => bootstrapNow(chat, opts));
  const pending = bootstraps.get(chat);
  if (pending) bootstrapGenerations.set(pending, generation);
  const result = serialized.catch(error => {
    const replacement = generation.replacement;
    if (replacement) return replacement;
    throw error;
  });
  if (replacing && previousGeneration) previousGeneration.replacement = result;
  return result;
}

async function bootstrapNow(chat: string, opts: BootstrapOpts): Promise<Slot> {
  await retirements.get(chat);
  if (g.__graffAcpShuttingDown) throw new Error("Desktop is shutting down");
  const live = slots.get(chat);
  const same = live !== undefined && live.sessionId !== null &&
    live.transport.usable && matchesBootstrap(live, opts);
  if (!opts.reset && same) return live;
  const recovering = live?.restart ? live : undefined;
  if (recovering?.restartReady) {
    await recovering.restartReady;
    if (slots.get(chat) !== live) return bootstrapNow(chat, opts);
  }
  const parked = opts.reset ? (forgetPark(chat), undefined) : takeParked(chat);
  await killSlot(chat, undefined, "bootstrap-replace");
  if (g.__graffAcpShuttingDown) throw new Error("Desktop is shutting down");
  if (slots.has(chat)) return bootstrapNow(chat, opts);
  const slot = spawnAgent(chat, {
    model: opts.model ?? recovering?.model ?? parked?.model ?? undefined,
    resume: opts.resume ?? recovering?.resume ?? recovering?.sessionId ?? parked?.resume ?? undefined,
    cwd: opts.cwd ?? recovering?.cwd ?? parked?.cwd ?? defaultRoot(),
    yolo: opts.yolo ?? recovering?.yolo ?? parked?.yolo ?? defaultYolo(),
    mcp: opts.mcp ?? recovering?.mcp ?? parked?.mcp ?? true,
  });
  const created = await initializeWorker(slot.transport, slot.cwd, async () => {
    slot.restart = true;
    slot.restartReady = retireWorker(slot.child);
    try { await slot.restartReady; }
    finally { if (slots.get(chat) === slot) slots.delete(chat); }
  }, HANDSHAKE_MS);
  slot.sessionId = created.sessionId;
  slot.cwd = bindSessionCwd(slot.cwd, created.cwd);
  attachmentStore().enrollSession(path.dirname(sessionFile(slot.cwd, slot.resume ?? slot.sessionId)), slot.child.pid);
  if (!slot.resume) registerSessionWriter(sessionFile(slot.cwd, slot.sessionId), slot.child, () => {
    if (slots.get(chat) === slot) void killSlot(chat, undefined, "session-writer").catch(() => undefined);
  });
  await drainCommands(slot);
  if (slots.get(chat) !== slot) throw new Error("ACP startup was disposed. Retry to start a new worker.");
  return slot;
}

export async function GET() {
  // Health is a passive probe: report the binary and the live agent count
  // without spawning. Spawning here raced the UI's own bootstrap (two agents
  // per page load) — the POST bootstrap path is the only spawner.
  const bin = graffBin();
  const found = path.isAbsolute(bin) ? existsSync(bin) : true;
  if (!found) {
    return Response.json(
      {
        ok: false,
        detail: `graff binary not found at ${bin}`,
        hint: "Build graff (zig build) or set GRAFF_BIN. The native app speaks ACP via `graff acp`.",
      },
      { status: 502 },
    );
  }
  return Response.json({ ok: true, sessions: slots.size, cwd: defaultRoot(), home: os.homedir(), yolo: defaultYolo() });
}

export async function POST(req: NextRequest) {
  const body = (await req.json()) as {
    chat?: string;
    method?: string;
    params?: Record<string, unknown>;
    stream?: boolean;
  };
  const method = body.method ?? "";
  const chat = typeof body.chat === "string" && body.chat ? body.chat : DEFAULT_CHAT;
  const model = typeof body.params?.model === "string" ? body.params.model : undefined;
  try {
    if (method === "shutdown") {
      g.__graffAcpShuttingDown = true;
      await Promise.all([...new Set([...slots.keys(), ...retirements.keys(), ...parkedChats()])].map(chat => killSlot(chat, undefined, "shutdown")));
      return Response.json({ ok: true });
    }
    if (method === "dispose") {
      await killSlot(chat);
      return Response.json({ ok: true });
    }
    if (method === "dispose-page") {
      if (typeof body.params?.page === "string" && body.params.page) await killPage(body.params.page);
      return Response.json({ ok: true });
    }
    if (method === "bootstrap") {
      const resume =
        typeof body.params?.resume === "string" && SESSION_NAME_RE.test(body.params.resume) ? body.params.resume : undefined;
      const cwdParam = typeof body.params?.cwd === "string" && body.params.cwd.trim() ? body.params.cwd : undefined;
      const resolved = resolveRoot(cwdParam);
      if ("error" in resolved) return Response.json({ error: resolved.error }, { status: resolved.status });
      const yolo = typeof body.params?.yolo === "boolean" ? body.params.yolo : undefined;
      const mcp = typeof body.params?.mcp === "boolean" ? body.params.mcp : undefined;
      const slot = await bootstrap(chat, {
        model,
        reset: body.params?.reset === true,
        resume,
        cwd: cwdParam ? resolved.root : undefined,
        yolo,
        mcp,
      });
      return Response.json({ sessionId: slot.sessionId, cwd: slot.cwd, commands: slot.commands });
    }
    if (method === "session/permission") {
      const current = slots.get(chat);
      const { requestId, sessionId, optionId } = body.params ?? {};
      if (!current || typeof sessionId !== "string" || current.sessionId !== sessionId || typeof requestId !== "string" || !(optionId === null || typeof optionId === "string") || !current.transport.respondPermission(requestId, sessionId, optionId))
        return Response.json({ error: "Permission request is no longer active or response is invalid" }, { status: 409 });
      return Response.json({ ok: true });
    }
    const slot = await bootstrap(chat, { model });
    if (method === "session/cancel") {
      try {
        slot.transport.notify("session/cancel", body.params);
      } catch {
        // a dead transport means the turn is over regardless
      }
      await endTurn(slot);
      return Response.json({ ok: true });
    }
    if (method === "session/answer") {
      const checked = validateAnswer(body.params);
      if (!checked.ok) return Response.json({ error: checked.error }, { status: 400 });
      if (!slot.sessionId) return Response.json({ error: "session is no longer valid" }, { status: 409 });
      if (rememberAnswer(slot.answered, checked.value.callId) === "repeat") {
        return Response.json({ ok: true, callId: checked.value.callId });
      }
      try {
        slot.transport.notify("session/answer", { ...checked.value, sessionId: slot.sessionId });
      } catch (error) {
        slot.answered.delete(checked.value.callId);
        return Response.json({ error: error instanceof Error ? error.message : "notify failed" }, { status: 503 });
      }
      return Response.json({ ok: true, callId: checked.value.callId });
    }
    if (method === "session/idle") {
      slot.idleListeners += 1;
      cancelIdle(chat);
      const encoder = new TextEncoder();
      const stream = new ReadableStream<Uint8Array>({
        start(controller) {
          const send = (line: string) => {
            if (slot.streaming) return;
            try { controller.enqueue(encoder.encode(`${line}\n`)); } catch { /* closed */ }
          };
          const stop = slot.transport.subscribe(send);
          const close = () => {
            stop();
            slot.idleListeners = Math.max(0, slot.idleListeners - 1);
            if (slots.get(chat) === slot) watchIdle(chat, slot);
            try { controller.close(); } catch { /* already closed */ }
          };
          req.signal.addEventListener("abort", close, { once: true });
        },
      });
      return new Response(stream, { headers: { "content-type": "application/x-ndjson", "cache-control": "no-store" } });
    }
    if (method === "session/prompt") {
      cancelIdle(chat);
      if (slot.streaming) return Response.json({ error: "A turn is already active" }, { status: 409 });
      const promptParams = await prepareGuiPrompt(body.params);
      if (slot.streaming) return Response.json({ error: "A turn is already active" }, { status: 409 });
      attachmentStore().retainPrompt(promptParams, path.dirname(sessionFile(slot.cwd, slot.resume ?? slot.sessionId!)), slot.child.pid);
      slot.streaming = true;
      const { stream, pending } = createPromptStream(slot.transport,
        { ...promptParams, sessionId: slot.sessionId }, () => {
          try { slot.transport.notify("session/cancel", { sessionId: slot.sessionId }); } catch {}
          void endTurn(slot);
        });
      slot.pendingPrompt = pending;
      // Both rejection and success settle the gate without changing the wire outcome.
      const settled = () => {
        if (slot.pendingPrompt === pending) { slot.transport.clearPermissions(); slot.pendingPrompt = null; slot.streaming = false; }
        if (slots.get(chat) === slot) watchIdle(chat, slot);
      };
      void pending.then(settled, settled);
      return new Response(stream, { headers: { "content-type": "application/x-ndjson", "cache-control": "no-store" } });
    }
    const result = await rpc(slot, method, body.params);
    return Response.json({ result });
  } catch (err) {
    return Response.json(
      { error: err instanceof Error ? err.message : String(err) },
      { status: 502 },
    );
  }
}
