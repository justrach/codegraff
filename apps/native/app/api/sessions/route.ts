import { existsSync, readFileSync, statSync } from "node:fs";
import path from "node:path";
import { NextRequest } from "next/server";
import {
  MAX_FULL_BYTES,
  NAME_RE,
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

/** Same resolution as /api/acp: the workspace the agent itself runs in. */
function workspaceRoot(): string {
  if (process.env.GRAFF_ACP_CWD) return process.env.GRAFF_ACP_CWD;
  if (process.env.GRAFF_CWD) return process.env.GRAFF_CWD;
  const fromApp = path.resolve(process.cwd(), "../..");
  if (existsSync(path.join(fromApp, "build.zig"))) return fromApp;
  return process.cwd();
}

function str(v: unknown): string | null {
  return typeof v === "string" && v.length > 0 ? v : null;
}

function parseScope(raw: string | null): ListScope {
  if (raw === "local" || raw === "elsewhere") return raw;
  return "all";
}

export async function GET(req: NextRequest) {
  const root = workspaceRoot();
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
