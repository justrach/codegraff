// In-process ACP host — `graff-core.wasm` / createGraffAgent().
// Hand-written (same as acp.ts). No child process.

import { readFile } from "node:fs/promises";
import { ACP_PROTOCOL_VERSION, type AcpPromptResult, type AcpUpdate } from "./acp.ts";

export type GraffCoreExports = {
  memory: WebAssembly.Memory;
  graff_acp_in_ptr(): number;
  graff_acp_in_cap(): number;
  graff_acp_out_ptr(): number;
  graff_acp_out_len(): number;
  graff_acp_out_consume(): void;
  graff_acp_create(seed: bigint | number): void;
  graff_acp_feed(len: number): number;
};

export interface CreateGraffAgentOptions {
  /** Path, URL, or bytes of `graff-core.wasm`. */
  wasm: string | URL | Uint8Array | ArrayBuffer | WebAssembly.Module;
  seed?: number;
}

export interface GraffAgent {
  sessionId: string | null;
  request(method: string, params?: unknown): Promise<unknown>;
  notify(method: string, params?: unknown): void;
  onUpdate(fn: (update: AcpUpdate, sessionId?: string) => void): () => void;
  prompt(text: string): Promise<{ stopReason: string; updates: AcpUpdate[] }>;
  close(): Promise<void>;
}

const textEncoder = new TextEncoder();
const textDecoder = new TextDecoder();

function asExports(instance: WebAssembly.Instance): GraffCoreExports {
  return instance.exports as unknown as GraffCoreExports;
}

function writeIn(core: GraffCoreExports, line: string): void {
  const bytes = textEncoder.encode(line.endsWith("\n") ? line : `${line}\n`);
  const cap = core.graff_acp_in_cap();
  if (bytes.length > cap) throw new Error(`ACP line exceeds ${cap} bytes`);
  const ptr = core.graff_acp_in_ptr();
  new Uint8Array(core.memory.buffer, ptr, bytes.length).set(bytes);
  if (core.graff_acp_feed(bytes.length) !== 0) throw new Error("graff_acp_feed failed");
}

function takeOut(core: GraffCoreExports): string {
  const len = core.graff_acp_out_len();
  if (len === 0) return "";
  const ptr = core.graff_acp_out_ptr();
  const text = textDecoder.decode(new Uint8Array(core.memory.buffer, ptr, len));
  core.graff_acp_out_consume();
  return text;
}

async function compileWasm(
  wasm: CreateGraffAgentOptions["wasm"],
): Promise<WebAssembly.Module> {
  if (wasm instanceof WebAssembly.Module) return wasm;
  if (wasm instanceof Uint8Array) return WebAssembly.compile(wasm);
  if (wasm instanceof ArrayBuffer) return WebAssembly.compile(wasm);
  if (wasm instanceof URL) {
    const res = await fetch(wasm);
    return WebAssembly.compile(await res.arrayBuffer());
  }
  const bytes = await readFile(wasm);
  return WebAssembly.compile(bytes);
}

export async function createGraffAgent(opts: CreateGraffAgentOptions): Promise<GraffAgent> {
  const mod = await compileWasm(opts.wasm);
  const instance = await WebAssembly.instantiate(mod, {});
  const core = asExports(instance);
  if (typeof core.graff_acp_create !== "function") {
    throw new Error("wasm is missing graff_acp_create — rebuild with `zig build wasm-core`");
  }
  core.graff_acp_create(opts.seed ?? 1);

  const listeners = new Set<(update: AcpUpdate, sessionId?: string) => void>();
  let nextId = 1;
  let sessionId: string | null = null;

  const dispatchLines = (raw: string): unknown | undefined => {
    let lastResult: unknown;
    for (const line of raw.split("\n")) {
      const trimmed = line.trim();
      if (!trimmed) continue;
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
        continue;
      }
      if (msg.method === "session/update") {
        const update = msg.params?.update;
        if (update) {
          for (const fn of listeners) fn(update, msg.params?.sessionId);
        }
        continue;
      }
      if (msg.error) throw new Error(msg.error.message ?? "ACP error");
      if (msg.id !== undefined) lastResult = msg.result;
    }
    return lastResult;
  };

  const agent: GraffAgent = {
    get sessionId() {
      return sessionId;
    },
    set sessionId(value) {
      sessionId = value;
    },
    async request(method, params) {
      const id = nextId++;
      writeIn(core, JSON.stringify({ jsonrpc: "2.0", id, method, params }));
      return dispatchLines(takeOut(core));
    },
    notify(method, params) {
      writeIn(core, JSON.stringify({ jsonrpc: "2.0", method, params }));
      dispatchLines(takeOut(core));
    },
    onUpdate(fn) {
      listeners.add(fn);
      return () => {
        listeners.delete(fn);
      };
    },
    async prompt(text) {
      const updates: AcpUpdate[] = [];
      const off = agent.onUpdate((update) => {
        updates.push(update);
      });
      try {
        const result = (await agent.request("session/prompt", {
          sessionId: sessionId ?? "",
          prompt: [{ type: "text", text }],
        })) as AcpPromptResult;
        return { stopReason: result.stopReason, updates };
      } finally {
        off();
      }
    },
    close() {
      return Promise.resolve();
    },
  };
  return agent;
}

/** createGraffAgent + initialize + session/new. */
export async function graffAgent(opts: CreateGraffAgentOptions & { cwd?: string }): Promise<GraffAgent> {
  const agent = await createGraffAgent(opts);
  await agent.request("initialize", {
    protocolVersion: ACP_PROTOCOL_VERSION,
    clientCapabilities: { fs: {} },
  });
  const created = (await agent.request("session/new", {
    cwd: opts.cwd ?? "",
  })) as { sessionId?: string };
  if (!created?.sessionId) throw new Error("session/new returned no sessionId");
  agent.sessionId = created.sessionId;
  return agent;
}
