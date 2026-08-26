import { spawn, type ChildProcessWithoutNullStreams } from "node:child_process";
import { existsSync } from "node:fs";
import path from "node:path";
import { NextRequest } from "next/server";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

type Slot = {
  child: ChildProcessWithoutNullStreams;
  buf: string;
  nextId: number;
  sessionId: string | null;
  model: string | null;
};

const g = globalThis as typeof globalThis & { __graffAcp?: Slot };

function graffBin(): string {
  if (process.env.GRAFF_BIN) return process.env.GRAFF_BIN;
  const fromApp = path.resolve(process.cwd(), "../../zig-out/bin/graff");
  if (existsSync(fromApp)) return fromApp;
  const fromRoot = path.resolve(process.cwd(), "zig-out/bin/graff");
  if (existsSync(fromRoot)) return fromRoot;
  return "graff";
}

function workspace(): string {
  if (process.env.GRAFF_ACP_CWD) return process.env.GRAFF_ACP_CWD;
  if (process.env.GRAFF_CWD) return process.env.GRAFF_CWD;
  const fromApp = path.resolve(process.cwd(), "../..");
  if (existsSync(path.join(fromApp, "build.zig"))) return fromApp;
  return process.cwd();
}

function yolo(): boolean {
  const raw = process.env.GRAFF_YOLO;
  if (raw === "0" || raw === "false" || raw === "off" || raw === "no") return false;
  return true;
}

function killSlot() {
  const slot = g.__graffAcp;
  if (!slot) return;
  slot.child.kill("SIGTERM");
  g.__graffAcp = undefined;
}

function spawnAgent(model?: string): Slot {
  killSlot();
  const args = ["acp"];
  if (yolo()) args.push("--yolo");
  if (model) args.push("--model", model);
  const child = spawn(graffBin(), args, {
    stdio: ["pipe", "pipe", "inherit"],
    cwd: workspace(),
    env: process.env,
  });
  const slot: Slot = { child, buf: "", nextId: 1, sessionId: null, model: model ?? null };
  child.on("exit", () => {
    if (g.__graffAcp === slot) g.__graffAcp = undefined;
  });
  g.__graffAcp = slot;
  return slot;
}

function writeLine(slot: Slot, obj: unknown) {
  slot.child.stdin.write(`${JSON.stringify(obj)}\n`);
}

function readLine(slot: Slot, timeoutMs: number): Promise<string> {
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error("ACP agent timed out")), timeoutMs);
    const onData = () => {
      const nl = slot.buf.indexOf("\n");
      if (nl < 0) return;
      const line = slot.buf.slice(0, nl);
      slot.buf = slot.buf.slice(nl + 1);
      clearTimeout(timer);
      slot.child.stdout.off("data", onData);
      resolve(line);
    };
    slot.child.stdout.on("data", (chunk: Buffer) => {
      slot.buf += chunk.toString("utf8");
      onData();
    });
    onData();
  });
}

async function rpc(slot: Slot, method: string, params?: unknown): Promise<unknown> {
  const id = slot.nextId++;
  writeLine(slot, { jsonrpc: "2.0", id, method, params });
  for (;;) {
    const line = await readLine(slot, 30_000);
    let msg: { id?: unknown; result?: unknown; error?: { message?: string }; method?: string };
    try {
      msg = JSON.parse(line) as typeof msg;
    } catch {
      continue;
    }
    if (msg.method) continue;
    if (msg.id !== id) continue;
    if (msg.error) throw new Error(msg.error.message ?? "ACP error");
    return msg.result;
  }
}

async function bootstrap(model?: string, reset = false): Promise<Slot> {
  if (!reset && g.__graffAcp && (!model || g.__graffAcp.model === model) && g.__graffAcp.sessionId) {
    return g.__graffAcp;
  }
  const slot = spawnAgent(model);
  await rpc(slot, "initialize", { protocolVersion: 1, clientCapabilities: { fs: {} } });
  const created = (await rpc(slot, "session/new", { cwd: workspace() })) as {
    sessionId?: string;
  };
  if (!created?.sessionId) throw new Error("session/new returned no sessionId");
  slot.sessionId = created.sessionId;
  return slot;
}

export async function GET() {
  try {
    const slot = await bootstrap();
    return Response.json({ ok: true, sessionId: slot.sessionId });
  } catch (err) {
    return Response.json(
      {
        ok: false,
        detail: err instanceof Error ? err.message : String(err),
        hint: "Build graff (zig build) or set GRAFF_BIN. The native app speaks ACP via `graff acp`.",
      },
      { status: 502 },
    );
  }
}

export async function POST(req: NextRequest) {
  const body = (await req.json()) as { method?: string; params?: Record<string, unknown>; stream?: boolean };
  const method = body.method ?? "";
  try {
    if (method === "bootstrap") {
      const slot = await bootstrap(
        typeof body.params?.model === "string" ? body.params.model : undefined,
        body.params?.reset === true,
      );
      return Response.json({ sessionId: slot.sessionId });
    }
    const slot = await bootstrap(typeof body.params?.model === "string" ? body.params.model : undefined);
    if (method === "session/cancel") {
      writeLine(slot, { jsonrpc: "2.0", method: "session/cancel", params: body.params });
      return Response.json({ ok: true });
    }
    if (method === "session/prompt") {
      const id = slot.nextId++;
      const encoder = new TextEncoder();
      const stream = new ReadableStream({
        start(controller) {
          const onData = (chunk: Buffer) => {
            slot.buf += chunk.toString("utf8");
            let nl: number;
            while ((nl = slot.buf.indexOf("\n")) >= 0) {
              const line = slot.buf.slice(0, nl);
              slot.buf = slot.buf.slice(nl + 1);
              if (!line.trim()) continue;
              let msg: { id?: unknown; method?: string };
              try {
                msg = JSON.parse(line) as typeof msg;
              } catch {
                continue;
              }
              controller.enqueue(encoder.encode(`${line}\n`));
              if (msg.id === id && !msg.method) {
                slot.child.stdout.off("data", onData);
                controller.close();
                return;
              }
            }
          };
          slot.child.stdout.on("data", onData);
          writeLine(slot, {
            jsonrpc: "2.0",
            id,
            method: "session/prompt",
            params: { sessionId: slot.sessionId, ...body.params },
          });
        },
        cancel() {
          writeLine(slot, { jsonrpc: "2.0", method: "session/cancel", params: { sessionId: slot.sessionId } });
        },
      });
      return new Response(stream, {
        headers: { "content-type": "application/x-ndjson", "cache-control": "no-store" },
      });
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
