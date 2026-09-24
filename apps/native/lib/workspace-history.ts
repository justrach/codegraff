import { lstatSync, opendirSync, readFileSync, realpathSync, statSync } from "node:fs";
import path from "node:path";
import { homeDir, peekHeader, SESSION_EXT, SESSIONS_DIR } from "./session-store";

export type WorkspaceActivity = { path: string; lastActivityMs: number };

function entries(folder: string): string[] {
  const result: string[] = [];
  try {
    const dir = opendirSync(folder);
    try { for (let item; result.length < 4096 && (item = dir.readSync());) result.push(item.name); }
    finally { dir.closeSync(); }
  } catch { /* Missing or inaccessible history is not an app startup failure. */ }
  return result;
}

/** Registry entries are hints. Only an existing, readable session header makes
 * activity; generated checkout activity is attributed to its outer project. */
export function discoverWorkspaceHistory(known: string[] = [], home = homeDir(), saved: string[] = known): WorkspaceActivity[] {
  const roots = new Set<string>();
  const knownNames = new Map<string, string>();
  const savedRoots = new Set<string>();
  for (const root of saved) {
    try { if (path.isAbsolute(root)) savedRoots.add(realpathSync(root)); } catch {}
  }
  for (const root of known) {
    try { if (path.isAbsolute(root)) knownNames.set(realpathSync(root), path.normalize(root)); } catch {}
  }
  const add = (value: unknown) => {
    if (typeof value !== "string" || !path.isAbsolute(value)) return;
    try { const canonical = realpathSync(value); if (statSync(canonical).isDirectory()) roots.add(canonical); } catch { /* removed folder */ }
  };
  for (const root of [home, ...known]) add(root);
  const registry = path.join(home, ".graff/workspace-history");
  for (const name of entries(registry)) {
    if (!/^[a-f0-9]{64}\.json$/.test(name)) continue;
    try {
      const file = path.join(registry, name), stat = lstatSync(file);
      if (!stat.isFile() || stat.size > 8192) continue;
      const row = JSON.parse(readFileSync(file, "utf8"));
      if (row.version === 1) add(row.path);
    } catch { /* Partial, obsolete and malformed hints are ignored. */ }
  }
  const activity = new Map<string, number>();
  for (const root of roots) {
    let latest = 0;
    for (const folder of [path.join(root, SESSIONS_DIR), path.join(root, SESSIONS_DIR, "archived")]) {
      for (const name of entries(folder)) {
        if (!name.endsWith(SESSION_EXT)) continue;
        try {
          const file = path.join(folder, name), stat = lstatSync(file);
          if (!stat.isFile() || !stat.size) continue;
          const header = peekHeader(file, stat.size, false);
          if (!header) continue;
          const updated = typeof header.updated_ms === "number" && Number.isFinite(header.updated_ms) && header.updated_ms > 0
            ? header.updated_ms : stat.mtimeMs;
          latest = Math.max(latest, updated);
        } catch { /* A concurrent save/delete must not break other projects. */ }
      }
    }
    if (latest > 0) {
      // Generated session checkouts belong to the outer project. A folder
      // explicitly saved by the user remains an independent choice.
      const marker = `${path.sep}.graff${path.sep}worktrees${path.sep}`;
      const index = savedRoots.has(root) ? -1 : root.indexOf(marker);
      const owner = index > 0 ? root.slice(0, index) : root;
      const label = knownNames.get(owner) ?? owner;
      activity.set(label, Math.max(activity.get(label) ?? 0, latest));
    }
  }
  return [...activity].map(([path, lastActivityMs]) => ({ path, lastActivityMs }))
    .sort((a, b) => b.lastActivityMs - a.lastActivityMs || a.path.localeCompare(b.path));
}
