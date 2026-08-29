/** Browser side of /api/fs — workspace listing, file reads, open/reveal. */

const BASE = "/api/fs";

export type FsEntry = { name: string; dir: boolean; size: number };

export type FsDir = { root: string; path: string; dir: true; entries: FsEntry[] };

export type FsFile = {
  root: string;
  path: string;
  dir: false;
  size: number;
  binary: boolean;
  truncated: boolean;
  text: string;
};

export async function fsStat(path: string): Promise<FsDir | FsFile> {
  const res = await fetch(`${BASE}?path=${encodeURIComponent(path)}`, { cache: "no-store" });
  const body = (await res.json()) as (FsDir | FsFile) & { error?: string };
  if (!res.ok) throw new Error(body.error ?? `fs ${res.status}`);
  return body;
}

async function act(action: "open" | "reveal", path: string): Promise<void> {
  await fetch(BASE, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ action, path }),
  }).catch(() => {});
}

/** Reveal in Finder. */
export const fsReveal = (path: string) => act("reveal", path);

/** Open with the default app (editor for code, Preview for images…). */
export const fsOpen = (path: string) => act("open", path);

export const IMAGE_RE = /\.(png|jpe?g|gif|webp|svg|ico|bmp|avif)$/i;

/** Byte URL for a workspace file — <img src=…> in the pane. */
export const fsRawUrl = (path: string) => `${BASE}?path=${encodeURIComponent(path)}&raw=1`;

export function formatSize(bytes: number): string {
  if (bytes < 1024) return `${bytes} B`;
  if (bytes < 1024 * 1024) return `${(bytes / 1024).toFixed(bytes < 10 * 1024 ? 1 : 0)} KB`;
  return `${(bytes / (1024 * 1024)).toFixed(1)} MB`;
}

/* ── workspace changes (Codex-style review) ── */

export type GitFile = { path: string; add: number; del: number; untracked: boolean };

export type GitChanges = { root: string; files: GitFile[]; totalAdd: number; totalDel: number };

export async function gitChanges(): Promise<GitChanges> {
  const res = await fetch("/api/git", { cache: "no-store" });
  const body = (await res.json()) as GitChanges & { error?: string };
  if (!res.ok) throw new Error(body.error ?? `git ${res.status}`);
  return body;
}

export async function gitFileDiff(path: string): Promise<string> {
  const res = await fetch("/api/git", {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ path }),
  });
  const body = (await res.json()) as { diff?: string; error?: string };
  if (!res.ok) throw new Error(body.error ?? `git ${res.status}`);
  return body.diff ?? "";
}
