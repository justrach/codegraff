import { execFile } from "node:child_process";
import { promisify } from "node:util";
import path from "node:path";
const run = promisify(execFile);
export type ReviewScope = "all" | "staged" | "unstaged";
export type ReviewFile = { path: string; add: number; del: number; untracked: boolean; status: string; binary: boolean };
export type ReviewState = { root: string; branch: string; files: ReviewFile[]; totalAdd: number; totalDel: number;
  commits: { hash: string; author: string; subject: string }[]; worktrees: { path: string; branch: string }[] };
async function git(root: string, args: string[], diff = false) {
  try { return (await run("git", ["--no-pager", ...args], { cwd: root, timeout: 10000, maxBuffer: 4 * 1024 * 1024, env: { ...process.env, GIT_OPTIONAL_LOCKS: "0", GIT_LITERAL_PATHSPECS: "1" } })).stdout; }
  catch (error) { if (diff && (error as { code?: number }).code === 1) return (error as { stdout: string }).stdout; throw error; }
}
function scopeArgs(scope: ReviewScope) { return scope === "staged" ? ["--cached"] : scope === "unstaged" ? [] : ["HEAD"]; }
export async function reviewDiff(root: string, file: string, scope: ReviewScope = "all") {
  const resolved = path.resolve(root, file);
  if (!file || resolved === root || !resolved.startsWith(root + path.sep)) throw new Error("Expected a relative workspace file");
  const base = ["diff", "--no-ext-diff", "--no-textconv"];
  const untracked = await git(root, ["ls-files", "--others", "--exclude-standard", "--", file]);
  if (untracked && scope !== "staged") return git(root, [...base, "--no-index", "--", "/dev/null", file], true);
  const head = scope === "all" ? await git(root, ["rev-parse", "--verify", "HEAD"]).catch(() => "") : "";
  return git(root, [...base, ...(scope === "all" && !head ? ["--cached"] : scopeArgs(scope)), "--", file]);
}
export async function reviewState(root: string, scope: ReviewScope = "all"): Promise<ReviewState> {
  const [status, branch, log, worktreeText] = await Promise.all([
    git(root, ["status", "--porcelain=v1", "-z", "--untracked-files=all"]),
    git(root, ["branch", "--show-current"]).catch(() => ""),
    git(root, ["log", "-8", "--format=%h%x00%an%x00%s"]).catch(() => ""),
    git(root, ["worktree", "list", "--porcelain"]).catch(() => ""),
  ]);
  const entries = status.split("\0"); const files: ReviewFile[] = [];
  for (let i = 0; i < entries.length; i++) {
    const row = entries[i]; if (row.length < 4) continue;
    const code = row.slice(0, 2), file = row.slice(3);
    if (/[RC]/.test(code)) i++; // porcelain -z gives the destination followed by the old name.
    if (scope === "staged" && (code[0] === " " || code === "??")) continue;
    if (scope === "unstaged" && code[1] === " ") continue;
    files.push({ path: file, status: code, untracked: code === "??", add: 0, del: 0, binary: false });
  }
  // Bounded work: use aggregate numstat for tracked files, load untracked text only when opened.
  const stats = await git(root, ["diff", "--numstat", "-z", ...scopeArgs(scope)]).catch(() => git(root, ["diff", "--numstat", "-z", "--cached"]));
  const parts = stats.split("\0");
  for (let i = 0; i < parts.length; i++) {
    const [add, del, ...nameParts] = parts[i].split("\t"); const name = nameParts.join("\t"); let file = name;
    if (name === "") { i++; file = parts[++i]; }
    const entry = files.find(row => row.path === file);
    if (entry) { entry.add = Number(add) || 0; entry.del = Number(del) || 0; entry.binary = add === "-"; }
  }
  const worktrees = worktreeText.split("\n\n").filter(Boolean).map(block => ({
    path: block.split("\n").find(line => line.startsWith("worktree "))?.slice(9) || "",
    branch: block.split("\n").find(line => line.startsWith("branch "))?.slice(7).replace(/^refs\/heads\//, "") || "detached",
  }));
  return { root, branch: branch.trim() || "detached", files: files.sort((a, b) => a.path.localeCompare(b.path)),
    totalAdd: files.reduce((n, f) => n + f.add, 0), totalDel: files.reduce((n, f) => n + f.del, 0),
    commits: log.trim().split("\n").filter(Boolean).map(row => { const [hash, author, ...subject] = row.split("\0"); return { hash, author, subject: subject.join(" ") }; }), worktrees };
}
