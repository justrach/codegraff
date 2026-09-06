import { spawn, type ChildProcessByStdio } from "node:child_process";
import { existsSync, mkdirSync, writeFileSync } from "node:fs";
import os from "node:os";
import path from "node:path";
import type { Readable, Writable } from "node:stream";
import { NextRequest } from "next/server";
import type { AcpCommand } from "@/lib/acp";
import { AcpTransport } from "@/lib/acp-transport";
import { defaultRoot, resolveRoot } from "@/lib/server-root";
import { prepareGuiPrompt } from "@/lib/gui-skill-context";

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
};

const HANDSHAKE_MS = 120_000;
const RPC_MS = 30_000;

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
const g = globalThis as typeof globalThis & { __graffAcpSlots?: Map<string, Slot> };
const slots = (g.__graffAcpSlots ??= new Map<string, Slot>());
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

function killSlot(chat: string) {
  const slot = slots.get(chat);
  if (!slot) return;
  slots.delete(chat);
  try {
    slot.child.stdin.end();
  } catch {
    // already closed
  }
  const timer = setTimeout(() => {
    try {
      slot.child.kill("SIGTERM");
    } catch {
      // already gone
    }
  }, EXIT_GRACE_MS);
  timer.unref();
  slot.child.once("exit", () => clearTimeout(timer));
}

function killPage(page: string) {
  const prefix = `${page}:`;
  for (const chat of [...slots.keys()]) {
    if (chat.startsWith(prefix)) killSlot(chat);
  }
}

function spawnAgent(chat: string, opts: SpawnOpts): Slot {
  killSlot(chat);
  const args = ["acp"];
  if (opts.yolo) args.push("--yolo");
  if (opts.model) args.push("--model", opts.model);
  if (opts.resume) args.push("--resume", opts.resume);
  const child = spawn(graffBin(), args, {
    stdio: ["pipe", "pipe", "inherit"],
    cwd: opts.cwd,
    env: { ...process.env, GRAFF_DESKTOP_CHAT: chat, ...(!opts.mcp ? { GRAFF_MCP_CONFIG: mcpOffPath() } : {}) },
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
  };
  slot.transport = new AcpTransport(child, message => noteCommands(slot, message));
  child.on("error", (err) => {
    slot.spawnError = err;
  });
  child.on("exit", () => {
    if (slots.get(chat) === slot) slots.delete(chat);
  });
  slots.set(chat, slot);
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

/** The tab's live agent when it still matches what was asked for (model,
 * session file, workspace, approval mode); otherwise a fresh spawn. A
 * request that leaves a field out accepts whatever the live agent has. */
async function bootstrap(chat: string, opts: BootstrapOpts): Promise<Slot> {
  const live = slots.get(chat);
  const same =
    live !== undefined &&
    live.sessionId !== null &&
    (!opts.model || live.model === opts.model) &&
    (!opts.resume || live.resume === opts.resume) &&
    (!opts.cwd || live.cwd === opts.cwd) &&
    (opts.yolo === undefined || live.yolo === opts.yolo) &&
    (opts.mcp === undefined || live.mcp === opts.mcp);
  if (!opts.reset && same) return live;
  const slot = spawnAgent(chat, {
    model: opts.model,
    resume: opts.resume,
    cwd: opts.cwd ?? defaultRoot(),
    yolo: opts.yolo ?? defaultYolo(),
    mcp: opts.mcp ?? true,
  });
  await rpc(slot, "initialize", { protocolVersion: 1, clientCapabilities: { fs: {} } }, HANDSHAKE_MS);
  const created = (await rpc(slot, "session/new", { cwd: slot.cwd }, HANDSHAKE_MS)) as {
    sessionId?: string;
  };
  if (!created?.sessionId) throw new Error("session/new returned no sessionId");
  slot.sessionId = created.sessionId;
  await drainCommands(slot);
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
    if (method === "dispose") {
      killSlot(chat);
      return Response.json({ ok: true });
    }
    if (method === "dispose-page") {
      if (typeof body.params?.page === "string" && body.params.page) killPage(body.params.page);
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
    const slot = await bootstrap(chat, { model });
    if (method === "session/cancel") {
      slot.transport.notify("session/cancel", body.params);
      return Response.json({ ok: true });
    }
    if (method === "session/prompt") {
      if (slot.streaming) return Response.json({ error: "A turn is already active" }, { status: 409 });
      const promptParams = await prepareGuiPrompt(body.params);
      if (slot.streaming) return Response.json({ error: "A turn is already active" }, { status: 409 });
      slot.streaming = true;
      const encoder = new TextEncoder();
      let cancelled = false;
      const stream = new ReadableStream({
        start(controller) {
          void slot.transport.request("session/prompt", { ...promptParams, sessionId: slot.sessionId }, 24 * 60 * 60 * 1000,
            line => { if (!cancelled) controller.enqueue(encoder.encode(`${line}\n`)); })
            .then(() => { if (!cancelled) { cancelled = true; controller.close(); } })
            .catch(error => { if (!cancelled) { cancelled = true; controller.error(error); } })
            .finally(() => { slot.streaming = false; });
        },
        cancel() {
          if (cancelled) return; // Completed streams must not cancel a later turn.
          cancelled = true;
          try { slot.transport.notify("session/cancel", { sessionId: slot.sessionId }); } catch {}
        },
      });
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
