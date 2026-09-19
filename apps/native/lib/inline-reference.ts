import { stat } from "node:fs/promises";
import { execFile } from "node:child_process";
import { promisify } from "node:util";
import path from "node:path";
import { githubIssueUrlsFromRemote } from "./git-review";

const run = promisify(execFile);
export type InlineReference = { kind: "file"; path: string } | { kind: "browser"; url: string };

/** Files win over identically named branches. Never infer a remote from prose. */
export async function resolveInlineReference(root: string, target: string): Promise<InlineReference> {
  const file: InlineReference = { kind: "file", path: target };
  if (!target || target.includes("\0")) throw new Error("Invalid reference");
  const absolute = path.resolve(root, target);
  if (absolute !== root && !absolute.startsWith(root + path.sep)) return file;
  try { await stat(absolute); return file; }
  catch (error) { if (!["ENOENT", "ENOTDIR"].includes((error as NodeJS.ErrnoException).code ?? "")) throw error; }
  const git = async (args: string[]) => (await run("git", args, { cwd: root, timeout: 5000, maxBuffer: 65536 })).stdout.trim();
  // Exact refs only: no revision expressions, shell interpolation or network calls.
  try { await git(["check-ref-format", `refs/heads/${target}`]); }
  catch { return file; }
  let branch = false;
  for (const ref of [`refs/heads/${target}`, `refs/remotes/origin/${target}`]) {
    try { await git(["show-ref", "--verify", "--quiet", ref]); branch = true; break; }
    catch { /* Not this ref. */ }
  }
  if (!branch) return file;
  const remote = await git(["remote", "get-url", "origin"]).catch(() => "");
  const github = githubIssueUrlsFromRemote(remote);
  if (!github) return file;
  const base = github.list.slice(0, -"/issues".length);
  const url = new URL(`${base}/tree/${target.split("/").map(encodeURIComponent).join("/")}`);
  if (url.protocol !== "https:" || url.hostname !== "github.com" || url.username || url.password) return file;
  return { kind: "browser", url: url.href };
}
