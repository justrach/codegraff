import { closeSync, existsSync, mkdirSync, openSync, readdirSync, readFileSync, readSync, renameSync, statSync, unlinkSync } from "node:fs";
import path from "node:path";
import { NextRequest } from "next/server";
import { resolveRoot } from "@/lib/server-root";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

// graff autosaves every conversation to `<cwd>/.graff/sessions/<name>.session.json`
// (src/session_index.zig owns the layout). The header — provider, model, title,
// updated_ms — is written before the (possibly multi-MB) messages array, so the
// list peeks the prefix instead of parsing whole files.
const SESSIONS_DIR = ".graff/sessions";
// Archived chats leave the list but stay on disk, next to graff's own
// sessions, so a chat can be put away without losing the conversation.
const ARCHIVE_DIR = ".graff/sessions/archived";
const EXT = ".session.json";
const NAME_RE = /^[A-Za-z0-9][A-Za-z0-9._-]*$/;
const PEEK_BYTES = 64 * 1024;
const MAX_FULL_BYTES = 16 * 1024 * 1024;

type Header = { title?: unknown; updated_ms?: unknown; model?: unknown; provider?: unknown };

export type StoredSessionRow = {
  name: string;
  title: string | null;
  updatedMs: number;
  model: string | null;
  provider: string | null;
  size: number;
};

function str(v: unknown): string | null {
  return typeof v === "string" && v.length > 0 ? v : null;
}

function peekHeader(file: string, size: number): Header | null {
  const fd = openSync(file, "r");
  try {
    const want = Math.min(size, PEEK_BYTES);
    const buf = Buffer.alloc(want);
    const n = readSync(fd, buf, 0, want, 0);
    const text = buf.toString("utf8", 0, n);
    // Quotes inside string values are escaped in the file, so the raw needle
    // only matches the real top-level key.
    const idx = text.indexOf('"messages":');
    if (idx < 0) return null;
    let head = text.slice(0, idx).trimEnd();
    if (head.endsWith(",")) head = head.slice(0, -1);
    return JSON.parse(`${head}}`) as Header;
  } catch {
    return null;
  } finally {
    closeSync(fd);
  }
}

function rowFor(dir: string, entry: string): StoredSessionRow | null {
  const name = entry.slice(0, -EXT.length);
  if (!NAME_RE.test(name)) return null;
  const file = path.join(dir, entry);
  let size = 0;
  let mtimeMs = 0;
  try {
    const st = statSync(file);
    if (!st.isFile()) return null;
    size = st.size;
    mtimeMs = st.mtimeMs;
  } catch {
    return null;
  }
  const header = size > 0 ? peekHeader(file, size) : null;
  const updated = typeof header?.updated_ms === "number" && header.updated_ms > 0 ? header.updated_ms : Math.round(mtimeMs);
  return {
    name,
    title: str(header?.title),
    updatedMs: updated,
    model: str(header?.model),
    provider: str(header?.provider),
    size,
  };
}

export async function GET(req: NextRequest) {
  // `?root=` is the workspace whose sessions are wanted (each workspace
  // keeps its own .graff/sessions); absent, the agent's default workspace.
  const resolved = resolveRoot(req.nextUrl.searchParams.get("root"));
  if ("error" in resolved) return Response.json({ error: resolved.error }, { status: resolved.status });
  const root = resolved.root;
  const dir = path.join(root, SESSIONS_DIR);
  const name = req.nextUrl.searchParams.get("name");
  if (name !== null) {
    if (!NAME_RE.test(name)) return Response.json({ error: "bad session name" }, { status: 400 });
    const file = path.join(dir, `${name}${EXT}`);
    if (!existsSync(file)) return Response.json({ error: "no such session" }, { status: 404 });
    const st = statSync(file);
    if (st.size > MAX_FULL_BYTES) return Response.json({ error: "session too large to open" }, { status: 413 });
    try {
      const parsed = JSON.parse(readFileSync(file, "utf8")) as Header & { messages?: unknown };
      return Response.json({
        name,
        title: str(parsed.title),
        model: str(parsed.model),
        provider: str(parsed.provider),
        updatedMs: typeof parsed.updated_ms === "number" ? parsed.updated_ms : Math.round(st.mtimeMs),
        size: st.size,
        messages: Array.isArray(parsed.messages) ? parsed.messages : [],
      });
    } catch (err) {
      return Response.json({ error: err instanceof Error ? err.message : String(err) }, { status: 502 });
    }
  }
  if (!existsSync(dir)) return Response.json({ cwd: root, sessions: [] });
  const rows: StoredSessionRow[] = [];
  for (const entry of readdirSync(dir)) {
    if (!entry.endsWith(EXT)) continue;
    const row = rowFor(dir, entry);
    if (row) rows.push(row);
  }
  rows.sort((a, b) => b.updatedMs - a.updatedMs);
  return Response.json({ cwd: root, sessions: rows });
}

/** Put a chat away (`?archive=1`, the default: the file moves under
 * `.graff/sessions/archived/`) or remove it for good. Either way it leaves
 * the sidebar; only delete loses the conversation. */
export async function DELETE(req: NextRequest) {
  const resolved = resolveRoot(req.nextUrl.searchParams.get("root"));
  if ("error" in resolved) return Response.json({ error: resolved.error }, { status: resolved.status });
  const name = req.nextUrl.searchParams.get("name");
  if (name === null || !NAME_RE.test(name)) return Response.json({ error: "bad session name" }, { status: 400 });
  const dir = path.join(resolved.root, SESSIONS_DIR);
  const file = path.join(dir, `${name}${EXT}`);
  if (!existsSync(file)) return Response.json({ error: "no such session" }, { status: 404 });
  const archive = req.nextUrl.searchParams.get("archive") !== "0";
  try {
    if (!archive) {
      unlinkSync(file);
      return Response.json({ ok: true, name, archived: false });
    }
    const target = path.join(resolved.root, ARCHIVE_DIR);
    mkdirSync(target, { recursive: true });
    let dest = path.join(target, `${name}${EXT}`);
    // Never overwrite an earlier archive of the same name.
    if (existsSync(dest)) dest = path.join(target, `${name}.${Date.now()}${EXT}`);
    renameSync(file, dest);
    return Response.json({ ok: true, name, archived: true });
  } catch (err) {
    return Response.json({ error: err instanceof Error ? err.message : String(err) }, { status: 502 });
  }
}
