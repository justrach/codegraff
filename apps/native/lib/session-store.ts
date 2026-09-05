import { closeSync, existsSync, openSync, readdirSync, readSync, statSync } from "node:fs";
import os from "node:os";
import path from "node:path";

/** Same layout `src/session_index.zig` owns. Header fields land before
 *  `messages`, so a list peeks the prefix instead of parsing whole files. */
export const SESSIONS_DIR = ".graff/sessions";
export const SESSION_EXT = ".session.json";
export const NAME_RE = /^[A-Za-z0-9][A-Za-z0-9._-]*$/;
export const PEEK_BYTES = 64 * 1024;
export const MAX_FULL_BYTES = 16 * 1024 * 1024;
export const PAGE_DEFAULT = 24;
export const PAGE_MAX = 80;

export type StoredSessionRow = {
  name: string;
  title: string | null;
  updatedMs: number;
  model: string | null;
  provider: string | null;
  size: number;
  workspace: string | null;
  /** `~/…` (or the path) when the save is not in the current cwd. */
  origin: string | null;
  local: boolean;
};

type Header = {
  title?: unknown;
  updated_ms?: unknown;
  model?: unknown;
  provider?: unknown;
  workspace?: unknown;
};

export type SessionPage = {
  sessions: StoredSessionRow[];
  nextCursor: string | null;
  total: number;
};

export type ListScope = "all" | "local" | "elsewhere";

function str(v: unknown): string | null {
  return typeof v === "string" && v.length > 0 ? v : null;
}

export function sameWorkspace(a: string, b: string): boolean {
  const left = a.replace(/\/+$/, "");
  const right = b.replace(/\/+$/, "");
  return left === right;
}

/** `~/…` when `dir` is under home; otherwise the path as-is. */
export function displayWorkspace(dir: string, home: string): string {
  if (!home) return dir;
  const root = home.replace(/\/+$/, "");
  if (dir === root || dir === home) return "~";
  if (dir.startsWith(`${root}/`)) return `~${dir.slice(root.length)}`;
  return dir;
}

export function clampLimit(raw: string | null | undefined, fallback = PAGE_DEFAULT): number {
  const n = raw == null || raw === "" ? fallback : Number.parseInt(raw, 10);
  if (!Number.isFinite(n) || n < 1) return fallback;
  return Math.min(PAGE_MAX, Math.floor(n));
}

export function encodeCursor(updatedMs: number, name: string): string {
  return `${updatedMs}:${name}`;
}

export function decodeCursor(cursor: string): { updatedMs: number; name: string } | null {
  const split = cursor.indexOf(":");
  if (split <= 0) return null;
  const updatedMs = Number.parseInt(cursor.slice(0, split), 10);
  const name = cursor.slice(split + 1);
  if (!Number.isFinite(updatedMs) || !NAME_RE.test(name)) return null;
  return { updatedMs, name };
}

export function homeDir(override?: string | null): string {
  const raw = override ?? process.env.HOME ?? os.homedir();
  return raw.replace(/\/+$/, "");
}

type HeaderPeek = Header | null;

export function peekHeader(file: string, size: number): HeaderPeek {
  const fd = openSync(file, "r");
  try {
    const want = Math.min(size, PEEK_BYTES);
    const buf = Buffer.alloc(want);
    const n = readSync(fd, buf, 0, want, 0);
    const text = buf.toString("utf8", 0, n);
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

function rowFor(dir: string, entry: string, fallbackWorkspace: string, local: boolean, home: string, cwd: string): StoredSessionRow | null {
  const name = entry.slice(0, -SESSION_EXT.length);
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
  const workspace = str(header?.workspace) ?? fallbackWorkspace;
  const here = local || sameWorkspace(workspace, cwd);
  return {
    name,
    title: str(header?.title),
    updatedMs: updated,
    model: str(header?.model),
    provider: str(header?.provider),
    size,
    workspace,
    origin: here ? null : displayWorkspace(workspace, home),
    local: here,
  };
}

function readDir(dir: string, workspace: string, local: boolean, home: string, cwd: string): StoredSessionRow[] {
  if (!existsSync(dir)) return [];
  const rows: StoredSessionRow[] = [];
  for (const entry of readdirSync(dir)) {
    if (!entry.endsWith(SESSION_EXT)) continue;
    const row = rowFor(dir, entry, workspace, local, home, cwd);
    if (row) rows.push(row);
  }
  return rows;
}

function newerFirst(a: StoredSessionRow, b: StoredSessionRow): number {
  if (a.updatedMs !== b.updatedMs) return b.updatedMs - a.updatedMs;
  return a.name < b.name ? -1 : a.name > b.name ? 1 : 0;
}

/** Cwd saves first (they win on the same base name), then `~/.graff/sessions`
 *  when that tree is a different workspace. ADR 0059 / #712. */
export function listSessionRows(cwd: string, home = homeDir()): StoredSessionRow[] {
  const cwdDir = path.join(cwd, SESSIONS_DIR);
  const rows = readDir(cwdDir, cwd, true, home, cwd);
  const seen = new Set(rows.map((r) => r.name));
  if (home && !sameWorkspace(home, cwd)) {
    for (const row of readDir(path.join(home, SESSIONS_DIR), home, false, home, cwd)) {
      if (seen.has(row.name)) continue;
      rows.push(row);
      seen.add(row.name);
    }
  }
  rows.sort(newerFirst);
  return rows;
}

export function matchesQuery(row: StoredSessionRow, q: string): boolean {
  const needle = q.trim().toLowerCase();
  if (!needle) return true;
  const hay = [row.title, row.name, row.model, row.provider, row.origin, row.workspace]
    .filter((v): v is string => typeof v === "string" && v.length > 0)
    .join("\n")
    .toLowerCase();
  return hay.includes(needle);
}

export function filterRows(rows: StoredSessionRow[], q?: string | null, scope: ListScope = "all"): StoredSessionRow[] {
  return rows.filter((row) => {
    if (scope === "local" && !row.local) return false;
    if (scope === "elsewhere" && row.local) return false;
    return matchesQuery(row, q ?? "");
  });
}

export function pageSessions(
  rows: StoredSessionRow[],
  opts: { limit?: number; cursor?: string | null; q?: string | null; scope?: ListScope } = {},
): SessionPage {
  const filtered = filterRows(rows, opts.q, opts.scope ?? "all");
  const limit = opts.limit && opts.limit > 0 ? Math.min(PAGE_MAX, Math.floor(opts.limit)) : PAGE_DEFAULT;
  let start = 0;
  if (opts.cursor) {
    const cur = decodeCursor(opts.cursor);
    if (cur) {
      const idx = filtered.findIndex((r) => r.updatedMs === cur.updatedMs && r.name === cur.name);
      if (idx >= 0) start = idx + 1;
      else {
        const older = filtered.findIndex(
          (r) => r.updatedMs < cur.updatedMs || (r.updatedMs === cur.updatedMs && r.name > cur.name),
        );
        start = older < 0 ? filtered.length : older;
      }
    }
  }
  const slice = filtered.slice(start, start + limit);
  const last = slice[slice.length - 1];
  const nextCursor = start + limit < filtered.length && last ? encodeCursor(last.updatedMs, last.name) : null;
  return { sessions: slice, nextCursor, total: filtered.length };
}

export function findSessionFile(cwd: string, name: string, home = homeDir()): { file: string; local: boolean; workspace: string } | null {
  if (!NAME_RE.test(name)) return null;
  const localFile = path.join(cwd, SESSIONS_DIR, `${name}${SESSION_EXT}`);
  if (existsSync(localFile)) return { file: localFile, local: true, workspace: cwd };
  if (home && !sameWorkspace(home, cwd)) {
    const homeFile = path.join(home, SESSIONS_DIR, `${name}${SESSION_EXT}`);
    if (existsSync(homeFile)) return { file: homeFile, local: false, workspace: home };
  }
  return null;
}
