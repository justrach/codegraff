/** Workspaces the native app knows about: the folders graff runs in. The
 * list and active pick use localStorage in the web client; the desktop also
 * persists them in its settings independently of the UI origin. Pure helpers so the list rules
 * are testable without a DOM. */

export const WORKSPACES_KEY = "graff.native.workspaces";
export const ACTIVE_WORKSPACE_KEY = "graff.native.workspace";
export const WORKSPACES_MAX = 50;

export type Workspace = {
  /** Absolute directory — the row's identity. */
  path: string;
  /** Startup context is visible, but is not a saved folder choice. */
  source?: "saved" | "startup" | "history";
  lastActivityMs?: number;
  /** Display name; defaults to the folder's basename. */
  name: string;
  /** Model new tabs in this workspace spawn with; unset = the harness pick. */
  model?: string;
  /** Auto-approve tools (`graff acp --yolo`); unset = the server's default. */
  yolo?: boolean;
  /** Start the configured MCP servers with each chat's agent; unset = yes.
   * Off, the agent runs with `GRAFF_MCP_CONFIG` pointing at an empty config. */
  mcp?: boolean;
};

/** Last path segment: `/Users/me/repo/` → `repo`; `/` stays `/`. */
export function basename(p: string): string {
  const trimmed = p.replace(/\/+$/, "");
  const last = trimmed.split("/").pop();
  return last && last.length > 0 ? last : trimmed || "/";
}

/** One-letter badge for the switcher: first letter or digit, upper-cased. */
export function monogram(name: string): string {
  const ch = name.trim().replace(/^[^A-Za-z0-9]+/, "")[0] ?? name.trim()[0];
  return (ch ?? "?").toUpperCase();
}

/** Trailing slashes are noise: `/a/b/` and `/a/b` are the same workspace. */
export function normalizePath(p: string): string {
  const t = p.trim();
  return t.length > 1 ? t.replace(/\/+$/, "") : t;
}

/** Add or update a workspace; the path is its identity, so re-adding a
 * folder updates its row in place instead of listing it twice. New rows
 * go last; the list is capped from the oldest end. */
export function upsertWorkspace(list: readonly Workspace[], ws: Workspace, max = WORKSPACES_MAX): Workspace[] {
  const path = normalizePath(ws.path);
  if (!path) return [...list];
  const name = ws.name.trim() || basename(path);
  const next: Workspace = { ...ws, path, name };
  const idx = list.findIndex((w) => w.path === path);
  const out = idx >= 0 ? list.map((w, i) => (i === idx ? { ...w, ...next } : w)) : [...list, next];
  const choices = out.filter(row => row.source !== "startup" && row.source !== "history");
  if (choices.length <= max) return out;
  const keep = new Set(choices.slice(-max).map(row => row.path));
  return out.filter(row => row.source === "startup" || row.source === "history" || keep.has(row.path));
}

export function removeWorkspace(list: readonly Workspace[], path: string): Workspace[] {
  const p = normalizePath(path);
  return list.filter((w) => w.path !== p);
}

export function findWorkspace(list: readonly Workspace[], path: string | null | undefined): Workspace | undefined {
  if (!path) return undefined;
  const p = normalizePath(path);
  return list.find((w) => w.path === p);
}

/** Preserve chosen rows, including a full list, when showing startup context. */
export function restoreWorkspaceSelection(saved: readonly Workspace[], remembered: string | null, root: string) {
  const list = [...saved];
  const normalized = normalizePath(root);
  if (normalized && !findWorkspace(list, normalized)) list.push({ path: normalized, name: basename(normalized), source: "startup" });
  const active = findWorkspace(list, remembered)?.path ?? findWorkspace(list, normalized)?.path ?? list[0]?.path ?? null;
  return { list, active };
}

export function savedWorkspaceChoices(list: readonly Workspace[]): Workspace[] {
  return list.filter(row => row.source !== "startup" && row.source !== "history").slice(-WORKSPACES_MAX)
    .map(({ lastActivityMs: _activity, ...choice }) => choice);
}

type ReadStore = Pick<Storage, "getItem">;
type WriteStore = Pick<Storage, "setItem" | "removeItem">;

function isWorkspace(value: unknown): value is Workspace {
  if (!value || typeof value !== "object") return false;
  const rec = value as Record<string, unknown>;
  return typeof rec.path === "string" && rec.path.length > 0 && typeof rec.name === "string";
}

export function loadWorkspaces(storage: ReadStore | null | undefined): Workspace[] {
  try {
    const raw = storage?.getItem(WORKSPACES_KEY);
    if (!raw) return [];
    const parsed: unknown = JSON.parse(raw);
    if (!Array.isArray(parsed)) return [];
    return parsed.filter(isWorkspace).reduce<Workspace[]>((acc, ws) => upsertWorkspace(acc, ws), []);
  } catch {
    return [];
  }
}

export function saveWorkspaces(storage: WriteStore | null | undefined, list: readonly Workspace[]): void {
  try {
    storage?.setItem(WORKSPACES_KEY, JSON.stringify(savedWorkspaceChoices(list)));
  } catch {
    // Private mode or a full quota: the list is a convenience, never a failure.
  }
}

export function loadActiveWorkspace(storage: ReadStore | null | undefined): string | null {
  try {
    const raw = storage?.getItem(ACTIVE_WORKSPACE_KEY);
    return raw ? normalizePath(raw) : null;
  } catch {
    return null;
  }
}

export function saveActiveWorkspace(storage: WriteStore | null | undefined, path: string | null): void {
  try {
    if (path) storage?.setItem(ACTIVE_WORKSPACE_KEY, normalizePath(path));
    else storage?.removeItem(ACTIVE_WORKSPACE_KEY);
  } catch {
    // see saveWorkspaces
  }
}

/** Shell-safe form of a path for the "continue in the terminal" command. */
export function shellQuote(p: string): string {
  if (/^[A-Za-z0-9_./~@:+=-]+$/.test(p)) return p;
  return `'${p.replace(/'/g, "'\\''")}'`;
}

/** Suggestions never overwrite deliberate folder names/settings or consume their limit. */
export function mergeWorkspaceActivity(list: readonly Workspace[], activity: readonly { path: string; lastActivityMs: number }[]): Workspace[] {
  const rows = list.map(row => ({ ...row }));
  for (const item of activity) {
    if (!item.path || !Number.isFinite(item.lastActivityMs) || item.lastActivityMs <= 0) continue;
    const path = normalizePath(item.path), existing = rows.find(row => row.path === path);
    if (existing) { existing.lastActivityMs = item.lastActivityMs; if (existing.source === "startup") existing.source = "history"; }
    else rows.push({ path, name: basename(path), source: "history", lastActivityMs: item.lastActivityMs });
  }
  return rows;
}

export function workspaceSourceLabel(row: Pick<Workspace, "source">): string {
  return row.source === "history" ? "Session history" : row.source === "startup" ? "Startup folder" : "Saved folder";
}
export function compareWorkspaceActivity(a: Workspace, b: Workspace): number {
  return (b.lastActivityMs ?? 0) - (a.lastActivityMs ?? 0) || a.name.localeCompare(b.name);
}
