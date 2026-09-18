import type { StoredSession } from "./sessions";

export type CacheCheck = { status: "changed" | "unknown"; summary: string; reasons: string[]; next: string; bytes?: number };
const normalized = (path: string) => path.replace(/\/+$/, "") || "/";
export function formatSaveSize(bytes?: number): string | undefined {
  if (!bytes || bytes <= 0 || !Number.isFinite(bytes)) return undefined;
  if (bytes < 1024) return `${bytes} B`;
  if (bytes < 1024 * 1024) return `${Math.max(1, Math.round(bytes / 1024))} KB`;
  return `${(bytes / (1024 * 1024)).toFixed(bytes >= 10 * 1024 * 1024 ? 0 : 1)} MB`;
}

/** Local compatibility only. Matching metadata cannot prove provider cache retention
 * or equality of the actual system prompt, tool schemas, or request prefix. */
export function assessSavedCache(saved: Pick<StoredSession, "model" | "workspace" | "size"> & { cacheWorkspaceMatches?: boolean | null }, target: { model?: string; cwd?: string }): CacheCheck {
  const reasons: string[] = [];
  let changed = false;
  if (!saved.model || !target.model) reasons.push("Model comparison unavailable.");
  else if (saved.model !== target.model) {
    changed = true; reasons.push("The selected model differs from the saved model.");
  } else reasons.push("The selected model matches the save.");
  const workspaceMatches = saved.cacheWorkspaceMatches === undefined
    ? (saved.workspace && target.cwd ? normalized(saved.workspace) === normalized(target.cwd) : null)
    : saved.cacheWorkspaceMatches;
  if (workspaceMatches === null) reasons.push("Workspace comparison unavailable.");
  else if (!workspaceMatches) {
    changed = true; reasons.push("The workspace differs; prompt context and cache routing may change.");
  } else reasons.push("The workspace matches the save.");
  const bytes = typeof saved.size === "number" ? saved.size : undefined;
  const payload = formatSaveSize(bytes) ? `this save (${formatSaveSize(bytes)})` : "the full saved context";
  return {
    status: changed ? "changed" : "unknown",
    summary: changed ? "Prompt cache: reuse at risk" : "Prompt cache: reuse unverified",
    reasons,
    next: changed
      ? `Continue will send ${payload}. Cache reuse is at risk; /compact after that can break it further.`
      : `Continue will send ${payload}. Cache reuse is unverified until a real request.`,
    ...(bytes ? { bytes } : {}),
  };
}

/** Read a fresh save without bootstrapping an agent or sending a model prompt. */
export async function checkSavedCache(name: string, target: { model?: string; cwd?: string }, signal?: AbortSignal): Promise<CacheCheck> {
  const params = new URLSearchParams({ name, view: "metadata" });
  if (target.cwd) params.set("root", target.cwd);
  const response = await fetch(`/api/sessions?${params}`, { cache: "no-store", signal });
  if (!response.ok) throw new Error("Could not read the saved conversation.");
  return assessSavedCache(await response.json() as StoredSession, target);
}
