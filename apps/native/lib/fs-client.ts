/** Browser side of /api/fs, /api/git and /api/workspaces — workspace
 * listing, file reads, open/reveal, the uncommitted-changes review and the
 * folder browser. Every call takes the workspace `root` it is about; absent,
 * the server's default workspace answers. */

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

function query(params: Record<string, string | undefined>): string {
  const q = new URLSearchParams();
  for (const [k, v] of Object.entries(params)) if (v !== undefined) q.set(k, v);
  const s = q.toString();
  return s ? `?${s}` : "";
}

export async function fsStat(path: string, root?: string): Promise<FsDir | FsFile> {
  const res = await fetch(`${BASE}${query({ path, root })}`, { cache: "no-store" });
  const body = (await res.json()) as (FsDir | FsFile) & { error?: string };
  if (!res.ok) throw new Error(body.error ?? `fs ${res.status}`);
  return body;
}

async function act(action: "open" | "reveal", path: string, root?: string): Promise<void> {
  await fetch(BASE, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ action, path, root }),
  }).catch(() => {});
}

/** Reveal in Finder. */
export const fsReveal = (path: string, root?: string) => act("reveal", path, root);

/** Open with the default app (editor for code, Preview for images…). */
export const fsOpen = (path: string, root?: string) => act("open", path, root);

export const IMAGE_RE = /\.(png|jpe?g|gif|webp|svg|ico|bmp|avif)$/i;

/** Byte URL for a workspace file — <img src=…> in the pane. */
export const fsRawUrl = (path: string, root?: string) => `${BASE}${query({ path, raw: "1", root })}`;

export function formatSize(bytes: number): string {
  if (bytes < 1024) return `${bytes} B`;
  if (bytes < 1024 * 1024) return `${(bytes / 1024).toFixed(bytes < 10 * 1024 ? 1 : 0)} KB`;
  return `${(bytes / (1024 * 1024)).toFixed(1)} MB`;
}

/* ── workspace changes (Codex-style review) ── */

export type GitFile = { path: string; add: number; del: number; untracked: boolean };

export type GitChanges = { root: string; files: GitFile[]; totalAdd: number; totalDel: number };

export async function gitChanges(root?: string): Promise<GitChanges> {
  const res = await fetch(`/api/git${query({ root })}`, { cache: "no-store" });
  const body = (await res.json()) as GitChanges & { error?: string };
  if (!res.ok) throw new Error(body.error ?? `git ${res.status}`);
  return body;
}

export async function gitFileDiff(path: string, root?: string): Promise<string> {
  const res = await fetch("/api/git", {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ path, root }),
  });
  const body = (await res.json()) as { diff?: string; error?: string };
  if (!res.ok) throw new Error(body.error ?? `git ${res.status}`);
  return body.diff ?? "";
}

/* ── folder browser (New workspace) ── */

export type FolderEntry = { name: string; path: string; git: boolean };

export type FolderListing = {
  path: string;
  parent: string | null;
  git: boolean;
  home: string;
  default: string;
  entries: FolderEntry[];
};

/** One level of the machine's folders; `~` is the home directory. */
export async function browseFolders(path: string): Promise<FolderListing> {
  const res = await fetch(`/api/workspaces${query({ path })}`, { cache: "no-store" });
  const body = (await res.json()) as FolderListing & { error?: string };
  if (!res.ok) throw new Error(body.error ?? `workspaces ${res.status}`);
  return body;
}
