import { lstatSync, readdirSync } from "node:fs";
import path from "node:path";
import { filePreview } from "@/lib/file-preview";
import { isTraceId, summarizeTrace } from "@/lib/run-traces";
import { resolveRoot } from "@/lib/server-root";
import { NextRequest } from "next/server";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

const MAX_LIST = 40;

function tracesDir(root: string): string {
  return path.join(root, ".graff", "traces");
}

function resolveTrace(root: string, id: string): string | null {
  if (!isTraceId(id)) return null;
  const target = path.resolve(tracesDir(root), `${id}.jsonl`);
  const dir = tracesDir(root);
  if (target !== dir && !target.startsWith(dir + path.sep)) return null;
  return target;
}

export async function GET(req: NextRequest) {
  const resolved = resolveRoot(req.nextUrl.searchParams.get("root"));
  if ("error" in resolved) return Response.json({ error: resolved.error }, { status: resolved.status });
  const id = req.nextUrl.searchParams.get("id");
  if (id) {
    const file = resolveTrace(resolved.root, id);
    if (!file) return Response.json({ error: "unknown trace" }, { status: 400 });
    try {
      if (lstatSync(file).isSymbolicLink()) return Response.json({ error: "unknown trace" }, { status: 404 });
      const preview = await filePreview(file);
      if (preview.binary) return Response.json({ error: "trace is not text" }, { status: 415 });
      const parsed = summarizeTrace(id, preview.text);
      return Response.json({ ...parsed, truncated: preview.truncated }, { headers: { "cache-control": "no-store" } });
    } catch {
      return Response.json({ error: "trace not found" }, { status: 404 });
    }
  }
  let names: string[] = [];
  try { names = readdirSync(tracesDir(resolved.root)); } catch {
    return Response.json({ traces: [] }, { headers: { "cache-control": "no-store" } });
  }
  const rows = [];
  for (const name of names) {
    if (!name.endsWith(".jsonl")) continue;
    const stem = name.slice(0, -".jsonl".length);
    const file = resolveTrace(resolved.root, stem);
    if (!file) continue;
    try {
      const st = lstatSync(file);
      if (!st.isFile() || st.isSymbolicLink()) continue;
      const preview = await filePreview(file);
      if (preview.binary) continue;
      const { summary } = summarizeTrace(stem, preview.text);
      rows.push({ ...summary, mtime: st.mtimeMs, bytes: st.size, truncated: preview.truncated });
    } catch { /* skip unreadable */ }
  }
  rows.sort((a, b) => b.mtime - a.mtime);
  return Response.json({ traces: rows.slice(0, MAX_LIST) }, { headers: { "cache-control": "no-store" } });
}
