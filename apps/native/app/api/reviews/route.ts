import { execFile } from "node:child_process";
import { promisify } from "node:util";
import { NextRequest } from "next/server";
import { parsePrList } from "@/lib/github-reviews";
import { resolveRoot } from "@/lib/server-root";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";
const run = promisify(execFile);

async function gh(root: string, args: string[]) {
  return run("gh", args, { cwd: root, timeout: 20000, encoding: "utf8" });
}

export async function GET(req: NextRequest) {
  const resolved = resolveRoot(req.nextUrl.searchParams.get("root"));
  if ("error" in resolved) return Response.json({ error: resolved.error }, { status: resolved.status });
  try {
    await gh(resolved.root, ["auth", "status"]);
  } catch {
    return Response.json({ ok: false, needAuth: true, prs: [] });
  }
  const number = req.nextUrl.searchParams.get("number");
  try {
    if (number) {
      const { stdout } = await gh(resolved.root, ["pr", "view", number, "--json", "number,title,author,url,isDraft,reviewDecision,headRefName,statusCheckRollup,body,reviews,comments"]);
      return Response.json({ ok: true, pr: JSON.parse(stdout) });
    }
    const { stdout } = await gh(resolved.root, ["pr", "list", "--json", "number,title,author,url,isDraft,reviewDecision,headRefName,statusCheckRollup"]);
    return Response.json({ ok: true, needAuth: false, prs: parsePrList(JSON.parse(stdout)) });
  } catch (error) {
    return Response.json({ error: error instanceof Error ? error.message : String(error) }, { status: 500 });
  }
}

export async function POST(req: Request) {
  const body = await req.json().catch(() => null);
  if (!body || typeof body !== "object") return Response.json({ error: "expected JSON" }, { status: 400 });
  const resolved = resolveRoot(typeof body.root === "string" ? body.root : null);
  if ("error" in resolved) return Response.json({ error: resolved.error }, { status: resolved.status });
  const number = String(body.number ?? "");
  const event = body.event === "APPROVE" ? "approve" : body.event === "REQUEST_CHANGES" ? "request-changes" : "comment";
  const text = typeof body.body === "string" ? body.body : "";
  if (!/^\d+$/.test(number)) return Response.json({ error: "invalid pull request" }, { status: 400 });
  try {
    const args = ["pr", "review", number, `--${event}`];
    if (text) args.push("--body", text);
    await gh(resolved.root, args);
    return Response.json({ ok: true });
  } catch (error) {
    return Response.json({ error: error instanceof Error ? error.message : String(error) }, { status: 500 });
  }
}
