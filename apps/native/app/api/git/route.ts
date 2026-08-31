import { execFile } from "node:child_process";
import { existsSync } from "node:fs";
import path from "node:path";
import { promisify } from "node:util";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

const run = promisify(execFile);

/** Same resolution as /api/acp: the workspace the agent itself runs in. */
function workspaceRoot(): string {
  if (process.env.GRAFF_ACP_CWD) return process.env.GRAFF_ACP_CWD;
  if (process.env.GRAFF_CWD) return process.env.GRAFF_CWD;
  const fromApp = path.resolve(process.cwd(), "../..");
  if (existsSync(path.join(fromApp, "build.zig"))) return fromApp;
  return process.cwd();
}

async function git(args: string[], cwd: string): Promise<string> {
  const { stdout } = await run("git", args, { cwd, maxBuffer: 8 * 1024 * 1024 });
  return stdout;
}

/** The working tree's uncommitted story, Codex-review shaped: per-file
 * +adds/−dels plus the unified diff, untracked files included. */
export async function GET() {
  const root = workspaceRoot();
  try {
    const [numstat, untrackedRaw] = await Promise.all([
      git(["diff", "--numstat"], root),
      git(["ls-files", "--others", "--exclude-standard"], root),
    ]);
    const files: { path: string; add: number; del: number; untracked: boolean }[] = [];
    for (const line of numstat.split("\n")) {
      if (!line.trim()) continue;
      const [add, del, file] = line.split("\t");
      if (!file) continue;
      files.push({ path: file, add: Number(add) || 0, del: Number(del) || 0, untracked: false });
    }
    const untracked = untrackedRaw.split("\n").filter(Boolean);
    for (const file of untracked) {
      let add = 0;
      try {
        const wc = await git(["diff", "--numstat", "--no-index", "/dev/null", file], root).catch((err) => {
          // git diff --no-index exits 1 when files differ; the diff is still on stdout
          const out = (err as { stdout?: string }).stdout;
          if (typeof out === "string") return out;
          throw err;
        });
        const first = wc.split("\n")[0]?.split("\t")[0];
        add = Number(first) || 0;
      } catch {
        // binary or unreadable; list it with no count
      }
      files.push({ path: file, add, del: 0, untracked: true });
    }
    files.sort((a, b) => a.path.localeCompare(b.path));
    return Response.json({
      ok: true,
      root,
      files,
      totalAdd: files.reduce((n, f) => n + f.add, 0),
      totalDel: files.reduce((n, f) => n + f.del, 0),
    });
  } catch (err) {
    return Response.json({ error: err instanceof Error ? err.message : String(err) }, { status: 500 });
  }
}

/** POST {path} → the unified diff for one file (or its full content when untracked). */
export async function POST(req: Request) {
  const root = workspaceRoot();
  const body = (await req.json()) as { path?: string };
  const file = body.path ?? "";
  const target = path.resolve(root, file);
  if (target !== root && !target.startsWith(root + path.sep)) {
    return Response.json({ error: "path escapes the workspace" }, { status: 400 });
  }
  try {
    let diff = await git(["diff", "--", file], root);
    if (!diff.trim()) {
      // Untracked: diff against /dev/null so new files render as all-adds.
      diff = await git(["diff", "--no-index", "--", "/dev/null", file], root).catch((err) => {
        const out = (err as { stdout?: string }).stdout;
        if (typeof out === "string") return out;
        throw err;
      });
    }
    return Response.json({ ok: true, path: file, diff });
  } catch (err) {
    return Response.json({ error: err instanceof Error ? err.message : String(err) }, { status: 500 });
  }
}
