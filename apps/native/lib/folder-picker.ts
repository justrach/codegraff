/** Path display, ranking and sort for the Open a folder picker.
 * Identity paths stay slash-stripped (`workspaces.normalizePath`); the field
 * and footer show a directory with a trailing `/` so the next segment is
 * obvious. Typing a name still ranks like `/model`; with an empty needle the
 * list follows Name / Modified (and an optional git-only filter). */

import { fuzzyScore } from "./fuzzy.ts";

/** POSIX directory form for display: `/Users/me` → `/Users/me/`; `/` stays `/`. */
export function displayDirPath(p: string): string {
  const n = p.replace(/\\/g, "/");
  if (!n) return n;
  if (n === "/") return "/";
  return n.endsWith("/") ? n : `${n}/`;
}

/** Compare two directory strings, ignoring a trailing separator. */
export function sameDir(a: string | null | undefined, b: string | null | undefined): boolean {
  if (a == null || b == null) return false;
  return normalizeDir(a) === normalizeDir(b);
}

/** True when `browse` is the listing already on screen.
 * `~` / `~/` is the listing's home, so typing it must not refetch. */
export function sameBrowse(
  browse: string | null | undefined,
  listingPath: string | null | undefined,
  home?: string | null,
): boolean {
  if (sameDir(browse, listingPath)) return true;
  if (!browse || !home) return false;
  return normalizeDir(browse) === "~" && sameDir(listingPath, home);
}

export function normalizeDir(p: string): string {
  const n = p.replace(/\\/g, "/").replace(/\/+$/, "");
  return n.length > 0 ? n : "/";
}

/** Join a parent directory and a child name without emitting `//`. */
export function joinDir(parent: string, name: string): string {
  const base = parent.replace(/\\/g, "/").replace(/\/+$/, "");
  const child = name.replace(/^\/+/, "");
  if (!base || base === "/") return `/${child}`;
  return `${base}/${child}`;
}

export type FolderQuery = {
  /** Directory to list, or `null` when the field is a bare name. */
  browse: string | null;
  /** Last path segment — the fuzzy needle. */
  needle: string;
};

/** Split a typed path into the directory to list and the name to rank.
 * `current` is the listing already on screen: typing that path without a
 * trailing slash is still "this folder", not parent + last segment. */
export function splitFolderQuery(typed: string, current?: string | null): FolderQuery {
  const t = typed.trim();
  if (!t) return { browse: null, needle: "" };
  if (current && sameDir(t, current)) return { browse: current, needle: "" };
  if (t === "~") return { browse: "~", needle: "" };
  if (t.endsWith("/") || t.endsWith("\\")) return { browse: t, needle: "" };
  const slash = Math.max(t.lastIndexOf("/"), t.lastIndexOf("\\"));
  if (slash < 0) return { browse: null, needle: t };
  const browse = t.slice(0, slash + 1);
  return { browse: browse || "/", needle: t.slice(slash + 1) };
}

export type RankableFolder = { name: string; path: string; git?: boolean; mtime?: number };

export type FolderSort = "name" | "modified";

export type FolderView = {
  sort: FolderSort;
  /** Name: Z–A; Modified: oldest first. */
  reverse: boolean;
  gitOnly: boolean;
};

export const DEFAULT_FOLDER_VIEW: FolderView = { sort: "name", reverse: false, gitOnly: false };
export const FOLDER_VIEW_KEY = "graff.native.folder-picker.view";

const NAME_COLLATOR = { sensitivity: "base" } as const;

/** Keep directory order when the needle is empty; otherwise closest `/model`
 * match first. Non-matches drop out. */
export function rankFolderEntries<T extends RankableFolder>(entries: readonly T[], needle: string): T[] {
  const q = needle.trim();
  if (!q) return [...entries];
  const scored: { item: T; score: number; idx: number }[] = [];
  for (let i = 0; i < entries.length; i += 1) {
    const item = entries[i];
    const score = fuzzyScore(item.name, q) ?? fuzzyScore(item.path, q);
    if (score == null) continue;
    scored.push({ item, score, idx: i });
  }
  scored.sort((a, b) => b.score - a.score || a.idx - b.idx);
  return scored.map((row) => row.item);
}

export function parseFolderView(raw: unknown): FolderView {
  if (!raw || typeof raw !== "object") return { ...DEFAULT_FOLDER_VIEW };
  const rec = raw as Record<string, unknown>;
  return {
    sort: rec.sort === "modified" ? "modified" : "name",
    reverse: rec.reverse === true,
    gitOnly: rec.gitOnly === true,
  };
}

export function loadFolderView(storage: Pick<Storage, "getItem"> | null | undefined): FolderView {
  try {
    const raw = storage?.getItem(FOLDER_VIEW_KEY);
    if (!raw) return { ...DEFAULT_FOLDER_VIEW };
    return parseFolderView(JSON.parse(raw) as unknown);
  } catch {
    return { ...DEFAULT_FOLDER_VIEW };
  }
}

export function saveFolderView(storage: Pick<Storage, "setItem"> | null | undefined, view: FolderView): void {
  try {
    storage?.setItem(FOLDER_VIEW_KEY, JSON.stringify(view));
  } catch {
    /* private mode / full quota — the in-memory pick still applies this session */
  }
}

/** Cycle Name ↔ Modified; a second click on the active sort reverses it. */
export function cycleFolderSort(view: FolderView, sort: FolderSort): FolderView {
  if (view.sort === sort) return { ...view, reverse: !view.reverse };
  return { ...view, sort, reverse: false };
}

export function sortFolderEntries<T extends RankableFolder>(entries: readonly T[], sort: FolderSort): T[] {
  const out = [...entries];
  if (sort === "modified") {
    out.sort((a, b) => (b.mtime ?? 0) - (a.mtime ?? 0) || a.name.localeCompare(b.name, undefined, NAME_COLLATOR));
  } else {
    out.sort((a, b) => a.name.localeCompare(b.name, undefined, NAME_COLLATOR));
  }
  return out;
}

/** Git filter, then fuzzy rank when typing, else Name / Modified. */
export function presentFolderEntries<T extends RankableFolder>(
  entries: readonly T[],
  needle: string,
  view: FolderView,
): T[] {
  const filtered = view.gitOnly ? entries.filter((entry) => entry.git) : entries;
  if (needle.trim()) return rankFolderEntries(filtered, needle);
  const sorted = sortFolderEntries(filtered, view.sort);
  return view.reverse ? sorted.reverse() : sorted;
}

const MIN = 60_000;
const HOUR = 60 * MIN;
const DAY = 24 * HOUR;
const WEEK = 7 * DAY;
const MONTH = 30 * DAY;
const YEAR = 365 * DAY;

/** Compact age for the Modified column: `now`, `12m`, `3h`, `2d`, `3w`, `5mo`, `2y`. */
export function formatFolderAge(mtime: number, now = Date.now()): string {
  if (!Number.isFinite(mtime) || mtime <= 0) return "";
  const age = Math.max(0, now - mtime);
  if (age < MIN) return "now";
  if (age < HOUR) return `${Math.round(age / MIN)}m`;
  if (age < DAY) return `${Math.round(age / HOUR)}h`;
  if (age < WEEK) return `${Math.round(age / DAY)}d`;
  if (age < MONTH) return `${Math.round(age / WEEK)}w`;
  if (age < YEAR) return `${Math.round(age / MONTH)}mo`;
  return `${Math.round(age / YEAR)}y`;
}

export function formatFolderModified(mtime: number): string {
  if (!Number.isFinite(mtime) || mtime <= 0) return "";
  return new Date(mtime).toLocaleString(undefined, { dateStyle: "medium", timeStyle: "short" });
}

/** Names the folder list already hides — creating one would look like a no-op. */
export const HIDDEN_FOLDER_NAMES = new Set(["node_modules", "zig-out", "target", "__pycache__"]);

/** Why this can't be a new folder name, or `null` when it can. */
export function folderNameError(raw: string): string | null {
  const name = raw.trim();
  if (!name) return "Name this folder.";
  if (name === "." || name === "..") return "That name isn't allowed.";
  if (/[/\\]/.test(name) || name.includes("\0")) return "A folder name can't contain /.";
  if (name.startsWith(".")) return "Dot-folders stay hidden in this list.";
  if (HIDDEN_FOLDER_NAMES.has(name)) return "That name stays hidden in this list.";
  if (name.length > 255) return "That name is too long.";
  return null;
}

/** Finder-style `untitled folder`, `untitled folder 2`, … avoiding collisions. */
export function uniqueFolderName(existing: readonly string[], base = "untitled folder"): string {
  const seed = base.trim() || "untitled folder";
  const taken = new Set(existing.map((name) => name.toLowerCase()));
  if (!taken.has(seed.toLowerCase())) return seed;
  for (let n = 2; n < 1000; n += 1) {
    const name = `${seed} ${n}`;
    if (!taken.has(name.toLowerCase())) return name;
  }
  return `${seed} ${Date.now()}`;
}
