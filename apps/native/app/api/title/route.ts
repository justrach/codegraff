import { spawn } from "node:child_process";
import { existsSync } from "node:fs";
import path from "node:path";
import { NextRequest } from "next/server";
import { defaultRoot, resolveRoot } from "@/lib/server-root";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

/** A tab's name, written by the model rather than chopped out of the prompt.
 * `graff title` is graff's own one-shot titler: it answers with a short
 * phrase and nothing else, on a small model, without touching the chat's
 * session. Best effort throughout — a tab keeps its provisional name when
 * this fails, so nothing here is allowed to break a send. */

function graffBin(): string {
  if (process.env.GRAFF_BIN) return process.env.GRAFF_BIN;
  const fromApp = path.resolve(process.cwd(), "../../zig-out/bin/graff");
  if (existsSync(fromApp)) return fromApp;
  const fromRoot = path.resolve(process.cwd(), "zig-out/bin/graff");
  if (existsSync(fromRoot)) return fromRoot;
  return "graff";
}

const TIMEOUT_MS = 20_000;
const MAX_PROMPT = 2_000;
const MAX_TITLE = 60;

/** graff prints the title on stdout and can print allocator warnings after
 * it; the first non-empty line is the answer. */
function firstLine(out: string): string | null {
  for (const raw of out.split("\n")) {
    const line = raw.trim();
    if (!line) continue;
    if (line.startsWith("error(") || line.startsWith("warning:")) return null;
    return line.replace(/^["'`]|["'`]$/g, "").slice(0, MAX_TITLE);
  }
  return null;
}

function titleFor(prompt: string, cwd: string): Promise<string | null> {
  return new Promise((resolve) => {
    let child: ReturnType<typeof spawn>;
    try {
      child = spawn(graffBin(), ["title", prompt], { cwd, stdio: ["ignore", "pipe", "ignore"], env: process.env });
    } catch {
      resolve(null);
      return;
    }
    let out = "";
    let done = false;
    const finish = (value: string | null) => {
      if (done) return;
      done = true;
      clearTimeout(timer);
      resolve(value);
    };
    const timer = setTimeout(() => {
      child.kill("SIGKILL");
      finish(null);
    }, TIMEOUT_MS);
    child.stdout?.on("data", (chunk: Buffer) => {
      out += chunk.toString();
      // The title is one line: stop as soon as it is complete rather than
      // waiting for the process to wind down.
      if (out.includes("\n")) {
        const line = firstLine(out);
        if (line) {
          child.kill("SIGKILL");
          finish(line);
        }
      }
    });
    child.on("error", () => finish(null));
    child.on("close", () => finish(firstLine(out)));
  });
}

export async function POST(req: NextRequest) {
  let body: { prompt?: unknown; cwd?: unknown };
  try {
    body = (await req.json()) as typeof body;
  } catch {
    return Response.json({ error: "bad request" }, { status: 400 });
  }
  const prompt = typeof body.prompt === "string" ? body.prompt.trim().slice(0, MAX_PROMPT) : "";
  if (!prompt) return Response.json({ error: "missing prompt" }, { status: 400 });
  const cwdParam = typeof body.cwd === "string" && body.cwd.trim() ? body.cwd : undefined;
  const resolved = resolveRoot(cwdParam);
  if ("error" in resolved) return Response.json({ error: resolved.error }, { status: resolved.status });
  const title = await titleFor(prompt, cwdParam ? resolved.root : defaultRoot());
  return Response.json({ title });
}
