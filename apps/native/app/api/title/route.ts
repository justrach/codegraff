import { generateTitle } from "@/lib/generate-title";
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

const MAX_PROMPT = 2_000;

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
  const title = await generateTitle(graffBin(), prompt, cwdParam ? resolved.root : defaultRoot());
  return Response.json({ title });
}
