import { existsSync, mkdirSync, readdirSync, statSync } from "node:fs";
import os from "node:os";
import path from "node:path";
import { NextRequest } from "next/server";
import { displayDirPath, folderNameError, HIDDEN_FOLDER_NAMES, joinDir } from "@/lib/folder-picker";
import { defaultRoot, expandHome } from "@/lib/server-root";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

/** Folder browser behind the "New workspace" picker: one directory level
 * at a time, folders only. Dot-folders and dependency trees are hidden —
 * nobody makes `node_modules` a workspace — and git roots plus mtime are
 * marked so the client can sort by name, recency, or repos. */

const HIDDEN = HIDDEN_FOLDER_NAMES;

export type FolderEntry = { name: string; path: string; git: boolean; mtime: number };

function dirMtime(p: string): number | null {
  try {
    const st = statSync(p);
    return st.isDirectory() ? Math.round(st.mtimeMs) : null;
  } catch {
    return null;
  }
}

export async function GET(req: NextRequest) {
  const raw = req.nextUrl.searchParams.get("path");
  const home = os.homedir();
  const target = path.resolve(expandHome(raw && raw.trim() ? raw.trim() : home));
  if (dirMtime(target) == null) return Response.json({ error: `not a directory: ${target}` }, { status: 404 });
  try {
    const entries: FolderEntry[] = [];
    for (const entry of readdirSync(target, { withFileTypes: true })) {
      if (entry.name.startsWith(".") || HIDDEN.has(entry.name)) continue;
      if (entry.isFile()) continue;
      const full = path.join(target, entry.name);
      const mtime = dirMtime(full);
      if (mtime == null) continue;
      entries.push({
        name: entry.name,
        path: joinDir(target, entry.name),
        git: existsSync(path.join(full, ".git")),
        mtime,
      });
    }
    entries.sort((a, b) => a.name.localeCompare(b.name, undefined, { sensitivity: "base" }));
    const parent = path.dirname(target);
    return Response.json({
      ok: true,
      path: displayDirPath(target),
      parent: parent === target ? null : parent,
      git: existsSync(path.join(target, ".git")),
      home,
      default: defaultRoot(),
      entries,
    });
  } catch (err) {
    return Response.json({ error: err instanceof Error ? err.message : String(err) }, { status: 500 });
  }
}

/** Create one folder in the listing currently on screen. */
export async function POST(req: NextRequest) {
  let body: { path?: unknown; name?: unknown };
  try {
    body = (await req.json()) as { path?: unknown; name?: unknown };
  } catch {
    return Response.json({ error: "expected json" }, { status: 400 });
  }
  if (!body || typeof body !== "object" || Array.isArray(body)) {
    return Response.json({ error: "expected an object" }, { status: 400 });
  }
  const name = typeof body.name === "string" ? body.name : "";
  const reason = folderNameError(name);
  if (reason) return Response.json({ error: reason }, { status: 400 });
  const label = name.trim();
  const parentRaw = typeof body.path === "string" ? body.path.trim() : "";
  const parent = path.resolve(expandHome(parentRaw || os.homedir()));
  if (dirMtime(parent) == null) return Response.json({ error: `not a directory: ${parent}` }, { status: 404 });
  const full = path.join(parent, label);
  if (path.dirname(full) !== parent) return Response.json({ error: "A folder name can't contain /." }, { status: 400 });
  if (existsSync(full)) return Response.json({ error: `already exists: ${label}` }, { status: 409 });
  try {
    mkdirSync(full);
  } catch (err) {
    const code = err && typeof err === "object" && "code" in err ? String((err as { code: unknown }).code) : "";
    if (code === "EEXIST") return Response.json({ error: `already exists: ${label}` }, { status: 409 });
    if (code === "EACCES" || code === "EPERM") {
      return Response.json({ error: `not allowed to create a folder here` }, { status: 403 });
    }
    return Response.json({ error: err instanceof Error ? err.message : String(err) }, { status: 500 });
  }
  return Response.json({ ok: true, path: joinDir(parent, label), parent: displayDirPath(parent) });
}
