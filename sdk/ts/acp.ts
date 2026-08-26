// SDK ACP host helper — hand-written, NOT auto-generated
// (contrast harness.ts/remote.ts's "Do not edit" header).
// Spawn `graff acp` and speak ACP v1 JSON-RPC on stdio. See docs/embedding.md.

import { spawn, type ChildProcessWithoutNullStreams } from "node:child_process";

export const ACP_PROTOCOL_VERSION = 1;

export type AcpUpdate = { sessionUpdate: string; [key: string]: unknown };

export type AcpPromptResult = { stopReason: string };

export interface SpawnAcpOptions {
  /** graff binary. Defaults to `GRAFF_BIN` or `graff` on PATH. */
  binary?: string;
  cwd?: string;
  env?: NodeJS.ProcessEnv;
  /** Extra flags after `acp` (e.g. `--no-local-tools`). */
  args?: string[];
  /** Default true — ACP has no `session/request_permission` yet. */
  yolo?: boolean;
  model?: string;
  /** Full argv for tests (`[process.execPath, fixture]`). */
  command?: string[];
}

export interface AcpConn {
  readonly child: ChildProcessWithoutNullStreams;
  sessionId: string | null;
  request(method: string, params?: unknown): Promise<unknown>;
  notify(method: string, params?: unknown): void;
  onUpdate(fn: (update: AcpUpdate, sessionId?: string) => void): () => void;
  prompt(text: string): Promise<{ stopReason: string; updates: AcpUpdate[] }>;
  close(): Promise<void>;
}

type Pending = {
  resolve: (value: unknown) => void;
  reject: (err: Error) => void;
};

function writeLine(child: ChildProcessWithoutNullStreams, obj: unknown): void {
  child.stdin.write(`${JSON.stringify(obj)}\n`);
}

function spawnChild(opts: SpawnAcpOptions): ChildProcessWithoutNullStreams {
  if (opts.command) {
    const [bin, ...argv] = opts.command;
    if (!bin) throw new Error("spawnAcp: command is empty");
    return spawn(bin, argv, {
      stdio: ["pipe", "pipe", "inherit"],
      cwd: opts.cwd,
      env: opts.env ?? process.env,
    });
  }
  const binary = opts.binary ?? process.env.GRAFF_BIN ?? "graff";
  const args = ["acp"];
  if (opts.yolo !== false) args.push("--yolo");
  if (opts.model) args.push("--model", opts.model);
  if (opts.args) args.push(...opts.args);
  return spawn(binary, args, {
    stdio: ["pipe", "pipe", "inherit"],
    cwd: opts.cwd,
    env: opts.env ?? process.env,
  });
}

/** Spawn `graff acp`. No handshake — call `request("initialize")` yourself. */
export function spawnAcp(opts: SpawnAcpOptions = {}): AcpConn {
  const child = spawnChild(opts);
  const pending = new Map<number, Pending>();
  const listeners = new Set<(update: AcpUpdate, sessionId?: string) => void>();
  let nextId = 1;
  let buf = "";
  let sessionId: string | null = null;
  let closed = false;

  const failAll = (err: Error) => {
    for (const wait of pending.values()) wait.reject(err);
    pending.clear();
  };

  const dispatch = (line: string) => {
    const trimmed = line.trim();
    if (!trimmed) return;
    let msg: {
      id?: number | string;
      method?: string;
      params?: { sessionId?: string; update?: AcpUpdate };
      result?: unknown;
      error?: { code?: number; message?: string };
    };
    try {
      msg = JSON.parse(trimmed) as typeof msg;
    } catch {
      return;
    }
    if (msg.method === "session/update") {
      const update = msg.params?.update;
      if (update) {
        for (const fn of listeners) fn(update, msg.params?.sessionId);
      }
      return;
    }
    if (msg.id === undefined) return;
    const wait = pending.get(Number(msg.id));
    if (!wait) return;
    pending.delete(Number(msg.id));
    if (msg.error) wait.reject(new Error(msg.error.message ?? "ACP error"));
    else wait.resolve(msg.result);
  };

  child.stdout.on("data", (chunk: Buffer | string) => {
    buf += typeof chunk === "string" ? chunk : chunk.toString("utf8");
    let nl: number;
    while ((nl = buf.indexOf("\n")) >= 0) {
      const line = buf.slice(0, nl);
      buf = buf.slice(nl + 1);
      dispatch(line);
    }
  });
  child.on("error", (err) => failAll(err instanceof Error ? err : new Error(String(err))));
  child.on("exit", (code, signal) => {
    if (closed && pending.size === 0) return;
    failAll(new Error(signal ? `graff acp killed (${signal})` : `graff acp exited ${code ?? "?"}`));
  });

  const conn: AcpConn = {
    child,
    get sessionId() {
      return sessionId;
    },
    set sessionId(value) {
      sessionId = value;
    },
    request(method, params) {
      const id = nextId++;
      return new Promise((resolve, reject) => {
        pending.set(id, { resolve, reject });
        writeLine(child, { jsonrpc: "2.0", id, method, params });
      });
    },
    notify(method, params) {
      writeLine(child, { jsonrpc: "2.0", method, params });
    },
    onUpdate(fn) {
      listeners.add(fn);
      return () => {
        listeners.delete(fn);
      };
    },
    async prompt(text) {
      const updates: AcpUpdate[] = [];
      const off = conn.onUpdate((update) => {
        updates.push(update);
      });
      try {
        const result = (await conn.request("session/prompt", {
          sessionId: sessionId ?? "",
          prompt: [{ type: "text", text }],
        })) as AcpPromptResult;
        return { stopReason: result.stopReason, updates };
      } finally {
        off();
      }
    },
    close() {
      if (closed) return Promise.resolve();
      closed = true;
      child.stdin.end();
      child.kill("SIGTERM");
      return new Promise((resolve) => {
        const done = () => resolve();
        child.once("exit", done);
        setTimeout(done, 1_000);
      });
    },
  };
  return conn;
}

/** Spawn `graff acp`, then `initialize` + `session/new`. */
export async function acp(opts: SpawnAcpOptions = {}): Promise<AcpConn> {
  const conn = spawnAcp(opts);
  try {
    await conn.request("initialize", {
      protocolVersion: ACP_PROTOCOL_VERSION,
      clientCapabilities: { fs: {} },
    });
    const created = (await conn.request("session/new", {
      cwd: opts.cwd ?? process.cwd(),
    })) as { sessionId?: string };
    if (!created?.sessionId) throw new Error("session/new returned no sessionId");
    conn.sessionId = created.sessionId;
    return conn;
  } catch (err) {
    await conn.close();
    throw err;
  }
}
