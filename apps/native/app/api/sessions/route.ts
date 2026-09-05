import { existsSync, mkdirSync, readFileSync, renameSync, statSync, unlinkSync } from "node:fs";
import path from "node:path";
import { NextRequest } from "next/server";
import { resolveRoot } from "@/lib/server-root";
import {
  MAX_FULL_BYTES,
  NAME_RE,
  SESSION_EXT,
  clampLimit,
  findSessionFile,
  homeDir,
  listSessionRows,
  pageSessions,
  peekHeader,
  type ListScope,
} from "@/lib/session-store";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

// graff autosaves every conversation to `<cwd>/.graff/sessions/<name>.session.json`
// (src/session_index.zig owns the layout). Reading, paging and searching that
// index lives in lib/session-store.ts; this route is the HTTP shape over it.
//
// Archived chats leave the list but stay on disk, in an `archived/` directory
// beside graff's own sessions, so a chat can be put away without losing it.
const ARCHIVE_SUBDIR = "archived";

function str(v: unknown): string | null {
  return typeof v === "string" && v.length > 0 ? v : null;
}

function parseScope(raw: string | null): ListScope {
  if (raw === "local" || raw === "elsewhere") return raw;
  return "all";
}

export async function GET(req: NextRequest) {
  // `?root=` is the workspace whose sessions are wanted (each workspace keeps
  // its own .graff/sessions); absent, the agent's default workspace.
  const resolved = resolveRoot(req.nextUrl.searchParams.get("root"));
  if ("error" in resolved) return Response.json({ error: resolved.error }, { status: resolved.status });
  const root = resolved.root;
  const home = homeDir();
  const name = req.nextUrl.searchParams.get("name");
  if (name !== null) {
    if (!NAME_RE.test(name)) return Response.json({ error: "bad session name" }, { status: 400 });
    const found = findSessionFile(root, name, home);
    if (!found) return Response.json({ error: "no such session" }, { status: 404 });
    const st = statSync(found.file);
    if (st.size > MAX_FULL_BYTES) return Response.json({ error: "session too large to open" }, { status: 413 });
    try {
      const parsed = JSON.parse(readFileSync(found.file, "utf8")) as {
        title?: unknown;
        updated_ms?: unknown;
        model?: unknown;
        provider?: unknown;
        workspace?: unknown;
        messages?: unknown;
      };
      const header = peekHeader(found.file, st.size);
      return Response.json({
        name,
        title: str(parsed.title),
        model: str(parsed.model),
        provider: str(parsed.provider),
        updatedMs: typeof parsed.updated_ms === "number" ? parsed.updated_ms : Math.round(st.mtimeMs),
        size: st.size,
        workspace: str(parsed.workspace) ?? str(header?.workspace) ?? found.workspace,
        local: found.local,
        messages: Array.isArray(parsed.messages) ? parsed.messages : [],
      });
    } catch (err) {
      return Response.json({ error: err instanceof Error ? err.message : String(err) }, { status: 502 });
    }
  }
  const page = pageSessions(listSessionRows(root, home), {
    limit: clampLimit(req.nextUrl.searchParams.get("limit")),
    cursor: req.nextUrl.searchParams.get("cursor"),
    q: req.nextUrl.searchParams.get("q"),
    scope: parseScope(req.nextUrl.searchParams.get("scope")),
  });
  return Response.json({ cwd: root, ...page });
}

/** Put a chat away (`?archive=1`, the default: the file moves into an
 * `archived/` directory beside it) or remove it for good. Either way it
 * leaves the list; only delete loses the conversation. A session saved in
 * the home tree rather than this workspace is archived where it lives. */
export async function DELETE(req: NextRequest) {
  const resolved = resolveRoot(req.nextUrl.searchParams.get("root"));
  if ("error" in resolved) return Response.json({ error: resolved.error }, { status: resolved.status });
  const name = req.nextUrl.searchParams.get("name");
  if (name === null || !NAME_RE.test(name)) return Response.json({ error: "bad session name" }, { status: 400 });
  const found = findSessionFile(resolved.root, name, homeDir());
  if (!found) return Response.json({ error: "no such session" }, { status: 404 });
  const archive = req.nextUrl.searchParams.get("archive") !== "0";
  try {
    if (!archive) {
      unlinkSync(found.file);
      return Response.json({ ok: true, name, archived: false });
    }
    const target = path.join(path.dirname(found.file), ARCHIVE_SUBDIR);
    mkdirSync(target, { recursive: true });
    let dest = path.join(target, `${name}${SESSION_EXT}`);
    // Never overwrite an earlier archive of the same name.
    if (existsSync(dest)) dest = path.join(target, `${name}.${Date.now()}${SESSION_EXT}`);
    renameSync(found.file, dest);
    return Response.json({ ok: true, name, archived: true });
  } catch (err) {
    return Response.json({ error: err instanceof Error ? err.message : String(err) }, { status: 502 });
  }
}
