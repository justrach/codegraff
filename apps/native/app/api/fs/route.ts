import { spawn } from "node:child_process";
import { readdirSync, readFileSync, statSync } from "node:fs";
import path from "node:path";
import { NextRequest } from "next/server";
import { resolveRoot } from "@/lib/server-root";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

/** Heavy or generated trees that only bury the folders people navigate to. */
const HIDDEN = new Set([".git", "node_modules", ".next", ".zig-cache", "zig-out", ".DS_Store"]);

const MAX_TEXT = 256 * 1024;

const IMAGE_TYPES: Record<string, string> = {
  ".png": "image/png",
  ".jpg": "image/jpeg",
  ".jpeg": "image/jpeg",
  ".gif": "image/gif",
  ".webp": "image/webp",
  ".svg": "image/svg+xml",
  ".ico": "image/x-icon",
  ".bmp": "image/bmp",
  ".avif": "image/avif",
};

/** Resolve a user-supplied path INSIDE the workspace or refuse it. */
function resolveInRoot(root: string, rel: string): string | null {
  const target = path.resolve(root, rel || ".");
  if (target !== root && !target.startsWith(root + path.sep)) return null;
  return target;
}

export async function GET(req: NextRequest) {
  // `?root=` picks the workspace (a tab's own cwd); paths stay inside it.
  const resolved = resolveRoot(req.nextUrl.searchParams.get("root"));
  if ("error" in resolved) return Response.json({ error: resolved.error }, { status: resolved.status });
  const root = resolved.root;
  const rel = req.nextUrl.searchParams.get("path") ?? "";
  const target = resolveInRoot(root, rel);
  if (!target) return Response.json({ error: "path escapes the workspace" }, { status: 400 });
  try {
    const stat = statSync(target);
    const relPath = path.relative(root, target);
    if (stat.isDirectory()) {
      const entries = readdirSync(target, { withFileTypes: true })
        .filter((e) => !HIDDEN.has(e.name))
        .map((e) => {
          const dir = e.isDirectory();
          let size = 0;
          if (!dir) {
            try {
              size = statSync(path.join(target, e.name)).size;
            } catch {
              // unstattable (dangling symlink); list it anyway
            }
          }
          return { name: e.name, dir, size };
        })
        .sort((a, b) => (a.dir === b.dir ? a.name.localeCompare(b.name) : a.dir ? -1 : 1));
      return Response.json({ ok: true, root, path: relPath, dir: true, entries });
    }
    // ?raw=1 streams the bytes themselves — how the pane shows images.
    if (req.nextUrl.searchParams.get("raw")) {
      const type = IMAGE_TYPES[path.extname(target).toLowerCase()] ?? "application/octet-stream";
      const bytes = readFileSync(target);
      return new Response(new Uint8Array(bytes), {
        headers: { "content-type": type, "cache-control": "no-store" },
      });
    }
    const buf = readFileSync(target);
    const head = buf.subarray(0, 8192);
    const binary = head.includes(0);
    const truncated = buf.length > MAX_TEXT;
    return Response.json({
      ok: true,
      root,
      path: relPath,
      dir: false,
      size: buf.length,
      binary,
      truncated,
      text: binary ? "" : buf.subarray(0, MAX_TEXT).toString("utf8"),
    });
  } catch (err) {
    return Response.json({ error: err instanceof Error ? err.message : String(err) }, { status: 404 });
  }
}

export async function POST(req: NextRequest) {
  const body = (await req.json()) as { action?: string; path?: string; root?: string };
  const resolved = resolveRoot(body.root);
  if ("error" in resolved) return Response.json({ error: resolved.error }, { status: resolved.status });
  const root = resolved.root;
  const target = resolveInRoot(root, body.path ?? "");
  if (!target) return Response.json({ error: "path escapes the workspace" }, { status: 400 });
  if (process.platform !== "darwin") {
    return Response.json({ error: "open/reveal is macOS-only here" }, { status: 501 });
  }
  if (body.action === "reveal") {
    spawn("open", ["-R", target], { stdio: "ignore", detached: true }).unref();
    return Response.json({ ok: true });
  }
  if (body.action === "open") {
    spawn("open", [target], { stdio: "ignore", detached: true }).unref();
    return Response.json({ ok: true });
  }
  return Response.json({ error: `unknown action: ${body.action}` }, { status: 400 });
}
