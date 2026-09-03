/** Workspaces the native app knows about: the folders graff runs in. The
 * list and the active pick live in this browser (localStorage); the server
 * only validates a root it is handed. Pure helpers here so the list rules
 * are testable without a DOM. */

export const WORKSPACES_KEY = "graff.native.workspaces";
export const ACTIVE_WORKSPACE_KEY = "graff.native.workspace";
export const WORKSPACES_MAX = 50;

export type Workspace = {
  /** Absolute directory — the row's identity. */
  path: string;
  /** Display name; defaults to the folder's basename. */
  name: string;
  /** Model new tabs in this workspace spawn with; unset = the harness pick. */
  model?: string;
  /** Auto-approve tools (`graff acp --yolo`); unset = the server's default. */
  yolo?: boolean;
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
  return out.length > max ? out.slice(out.length - max) : out;
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
    storage?.setItem(WORKSPACES_KEY, JSON.stringify(list.slice(-WORKSPACES_MAX)));
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
