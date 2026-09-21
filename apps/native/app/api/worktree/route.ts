import { spawn } from "node:child_process";
import { graffBin, parseCreate, runCommand, sanitizeSlug, slugFromCheckout } from "@/lib/worktree-cli";
import { resolveRoot } from "@/lib/server-root";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

function run(bin: string, args: string[], cwd: string, timeoutMs: number): Promise<{ code: number; stdout: string; stderr: string }> {
  return new Promise((resolve, reject) => {
    const child = spawn(bin, args, { cwd, env: process.env });
    let stdout = "";
    let stderr = "";
    const timer = setTimeout(() => {
      child.kill("SIGTERM");
      reject(new Error("worktree command timed out"));
    }, timeoutMs);
    child.stdout?.on("data", (chunk: Buffer) => { stdout += chunk.toString(); });
    child.stderr?.on("data", (chunk: Buffer) => { stderr += chunk.toString(); });
    child.on("error", err => { clearTimeout(timer); reject(err); });
    child.on("close", code => {
      clearTimeout(timer);
      resolve({ code: code ?? 1, stdout, stderr });
    });
  });
}

export async function POST(req: Request) {
  try {
    if (Number(req.headers.get("content-length")) > 16384) return Response.json({ error: "Message too large" }, { status: 413 });
    const body = await req.json();
    const resolved = resolveRoot(typeof body.root === "string" ? body.root : undefined);
    if ("error" in resolved) return Response.json({ error: resolved.error }, { status: resolved.status });
    const bin = graffBin();
    const action = body.action;
    if (action === "create") {
      const name = sanitizeSlug(typeof body.name === "string" ? body.name : "");
      if (!name) return Response.json({ error: "workspace name must be 1-64 letters, digits, '.', '_' or '-'" }, { status: 400 });
      const result = await run(bin, ["worktree", "create", name], resolved.root, 120_000);
      const parsed = parseCreate(result.stdout);
      if (result.code !== 0 || !parsed) {
        return Response.json({ error: result.stderr.trim() || result.stdout.trim() || "create failed" }, { status: 502 });
      }
      return Response.json(parsed);
    }
    if (action === "archive") {
      const name = sanitizeSlug(typeof body.name === "string" ? body.name : "")
        ?? slugFromCheckout(resolved.root);
      if (!name) return Response.json({ error: "not a task workspace" }, { status: 400 });
      const result = await run(bin, ["worktree", "archive", name], resolved.root, 60_000);
      if (result.code !== 0) return Response.json({ error: result.stderr.trim() || result.stdout.trim() || "archive failed" }, { status: 502 });
      return Response.json({ ok: true, output: result.stdout.trim() });
    }
    if (action === "run") {
      const name = sanitizeSlug(typeof body.name === "string" ? body.name : "")
        ?? slugFromCheckout(resolved.root);
      if (!name) return Response.json({ error: "not a task workspace" }, { status: 400 });
      return Response.json({ ok: true, name, command: runCommand(name) });
    }
    return Response.json({ error: "Unknown worktree action" }, { status: 400 });
  } catch (error) {
    return Response.json({ error: error instanceof Error ? error.message : "Worktree unavailable" }, { status: 502 });
  }
}
