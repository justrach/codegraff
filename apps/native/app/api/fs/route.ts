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

/** Bounds for the `@` picker's walk. A workspace can be someone's whole home
 *  directory, so the walk is capped rather than exhaustive: it stops long
 *  before it could stall the composer, and says so with `partial`. */
const SEARCH_SCAN_LIMIT = 20_000;
const SEARCH_RESULT_LIMIT = 40;
const SEARCH_MAX_DEPTH = 8;

/** Rank a candidate for the query, or -1 to drop it. A file-name match beats
 *  one buried in a parent directory, because a name is what someone typing
 *  into the picker means; shorter paths break ties, so `src/x.ts` sorts above
 *  a deeply vendored namesake. */
function score(rel: string, query: string): number {
  const name = rel.slice(rel.lastIndexOf(path.sep) + 1).toLowerCase();
  if (name.startsWith(query)) return 0;
  if (name.includes(query)) return 1;
  if (rel.toLowerCase().includes(query)) return 2;
  return -1;
}

/** Files under `root` matching `query`, best first. Directories never match:
 *  the picker mentions files, and `@[some/dir]` means nothing to the agent. */
function searchFiles(root: string, query: string): { matches: string[]; partial: boolean } {
  const hits: { rel: string; rank: number }[] = [];
  const queue: { dir: string; depth: number }[] = [{ dir: root, depth: 0 }];
  let scanned = 0;
  let partial = false;
  while (queue.length > 0) {
    const { dir, depth } = queue.shift()!;
    let entries;
    try {
      entries = readdirSync(dir, { withFileTypes: true });
    } catch {
      continue; // unreadable directory: skip it rather than fail the whole search
    }
    for (const entry of entries) {
      if (HIDDEN.has(entry.name) || entry.name.startsWith(".")) continue;
      if (++scanned > SEARCH_SCAN_LIMIT) {
        partial = true;
        queue.length = 0;
        break;
      }
      const full = path.join(dir, entry.name);
      if (entry.isDirectory()) {
        if (depth < SEARCH_MAX_DEPTH) queue.push({ dir: full, depth: depth + 1 });
        continue;
      }
      const rel = path.relative(root, full);
      const rank = score(rel, query);
      if (rank >= 0) hits.push({ rel, rank });
    }
  }
  hits.sort((a, b) => (a.rank === b.rank ? a.rel.length - b.rel.length : a.rank - b.rank));
  if (hits.length > SEARCH_RESULT_LIMIT) partial = true;
  return { matches: hits.slice(0, SEARCH_RESULT_LIMIT).map((h) => h.rel), partial };
}

export async function GET(req: NextRequest) {
  // `?root=` picks the workspace (a tab's own cwd); paths stay inside it.
  const resolved = resolveRoot(req.nextUrl.searchParams.get("root"));
  if ("error" in resolved) return Response.json({ error: resolved.error }, { status: resolved.status });
  const root = resolved.root;
  // `?q=` is the composer's @ picker, not the files pane: search, don't list.
  const q = req.nextUrl.searchParams.get("q");
  if (q !== null) {
    const query = q.trim().toLowerCase();
    const found = query ? searchFiles(root, query) : { matches: [], partial: false };
    return Response.json({ ok: true, root, query, ...found });
  }
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
