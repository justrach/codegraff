import { existsSync, readdirSync, statSync } from "node:fs";
import os from "node:os";
import path from "node:path";
import { NextRequest } from "next/server";
import { defaultRoot, expandHome } from "@/lib/server-root";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

/** Folder browser behind the "New workspace" picker: one directory level
 * at a time, folders only. Dot-folders and dependency trees are hidden —
 * nobody makes `node_modules` a workspace — and git roots are marked so a
 * repo stands out among its siblings. */

const HIDDEN = new Set(["node_modules", "zig-out", "target", "__pycache__"]);

export type FolderEntry = { name: string; path: string; git: boolean };

function isDir(p: string): boolean {
  try {
    return statSync(p).isDirectory();
  } catch {
    return false;
  }
}

export async function GET(req: NextRequest) {
  const raw = req.nextUrl.searchParams.get("path");
  const home = os.homedir();
  const target = path.resolve(expandHome(raw && raw.trim() ? raw.trim() : home));
  if (!isDir(target)) return Response.json({ error: `not a directory: ${target}` }, { status: 404 });
  try {
    const entries: FolderEntry[] = [];
    for (const entry of readdirSync(target, { withFileTypes: true })) {
      if (entry.name.startsWith(".") || HIDDEN.has(entry.name)) continue;
      const full = path.join(target, entry.name);
      if (!(entry.isDirectory() || (entry.isSymbolicLink() && isDir(full)))) continue;
      entries.push({ name: entry.name, path: full, git: existsSync(path.join(full, ".git")) });
    }
    entries.sort((a, b) => a.name.localeCompare(b.name, undefined, { sensitivity: "base" }));
    const parent = path.dirname(target);
    return Response.json({
      ok: true,
      path: target,
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
