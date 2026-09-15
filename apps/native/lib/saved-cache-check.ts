import type { StoredSession } from "./sessions";

export type CacheCheck = { status: "changed" | "unknown"; summary: string; reasons: string[] };
const normalized = (path: string) => path.replace(/\/+$/, "") || "/";

/** Local compatibility only. Matching metadata cannot prove provider cache retention
 * or equality of the actual system prompt, tool schemas, or request prefix. */
export function assessSavedCache(saved: Pick<StoredSession, "model" | "workspace"> & { cacheWorkspaceMatches?: boolean | null }, target: { model?: string; cwd?: string }): CacheCheck {
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
  return { status: changed ? "changed" : "unknown", summary: changed ? "Prompt cache: reuse at risk" : "Prompt cache: reuse unverified", reasons };
}

/** Read a fresh save without bootstrapping an agent or sending a model prompt. */
export async function checkSavedCache(name: string, target: { model?: string; cwd?: string }, signal?: AbortSignal): Promise<CacheCheck> {
  const params = new URLSearchParams({ name, view: "metadata" });
  if (target.cwd) params.set("root", target.cwd);
  const response = await fetch(`/api/sessions?${params}`, { cache: "no-store", signal });
  if (!response.ok) throw new Error("Could not read the saved conversation.");
  return assessSavedCache(await response.json() as StoredSession, target);
}
