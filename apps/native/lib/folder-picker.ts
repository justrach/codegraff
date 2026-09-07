/** Path display and query-aware ranking for the Open a folder picker.
 * Identity paths stay slash-stripped (`workspaces.normalizePath`); the field
 * and footer show a directory with a trailing `/` so the next segment is
 * obvious. Ranking is the `/model` fuzzy score. */

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

export type RankableFolder = { name: string; path: string };

/** Keep alpha order when the needle is empty; otherwise closest `/model`
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
