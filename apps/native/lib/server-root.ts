import { existsSync, statSync } from "node:fs";
import os from "node:os";
import path from "node:path";

/** Server side of workspaces. Every API route that touches the disk — the
 * ACP spawner, the session list, the files pane, git — resolves its root
 * here, so a `root` the browser hands over is checked in exactly one place. */

/** The workspace used when a request names none: the env pin, else the
 * repo root above `apps/native`, else the dev server's own cwd. */
export function defaultRoot(): string {
  if (process.env.GRAFF_ACP_CWD) return process.env.GRAFF_ACP_CWD;
  if (process.env.GRAFF_CWD) return process.env.GRAFF_CWD;
  const fromApp = path.resolve(process.cwd(), "../..");
  if (existsSync(path.join(fromApp, "build.zig"))) return fromApp;
  return process.cwd();
}

/** `~` and `~/x` mean the home directory; anything else is returned as is. */
export function expandHome(p: string): string {
  if (p === "~") return os.homedir();
  if (p.startsWith("~/")) return path.join(os.homedir(), p.slice(2));
  return p;
}

export type RootResolution = { root: string } | { error: string; status: number };

/** A caller-chosen workspace root (`?root=` or `body.root`): absolute and
 * an existing directory, normalised (no trailing slash) so path-escape
 * checks can compare prefixes. Empty or missing means the default. */
export function resolveRoot(raw: string | null | undefined): RootResolution {
  if (raw === null || raw === undefined || raw.trim() === "") return { root: defaultRoot() };
  const expanded = expandHome(raw.trim());
  if (!path.isAbsolute(expanded)) return { error: "workspace root must be an absolute path", status: 400 };
  const root = path.resolve(expanded);
  try {
    if (!statSync(root).isDirectory()) return { error: "workspace root is not a directory", status: 400 };
  } catch {
    return { error: `no such workspace directory: ${root}`, status: 404 };
  }
  return { root };
}
