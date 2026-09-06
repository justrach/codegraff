import { NextRequest } from "next/server";
import { resolveRoot } from "@/lib/server-root";
import { reviewState, reviewDiff, type ReviewScope } from "@/lib/git-review";
export const runtime = "nodejs";
export const dynamic = "force-dynamic";
const scopeOf = (value: unknown): ReviewScope => value === "staged" || value === "unstaged" ? value : "all";
export async function GET(req: NextRequest) {
  const resolved = resolveRoot(req.nextUrl.searchParams.get("root"));
  if ("error" in resolved) return Response.json({ error: resolved.error }, { status: resolved.status });
  try { return Response.json(await reviewState(resolved.root, scopeOf(req.nextUrl.searchParams.get("scope")))); }
  catch (error) { return Response.json({ error: error instanceof Error ? error.message : String(error) }, { status: 500 }); }
}
export async function POST(req: Request) {
  const body = await req.json(); const resolved = resolveRoot(body.root);
  if ("error" in resolved) return Response.json({ error: resolved.error }, { status: resolved.status });
  try { return Response.json({ path: body.path, diff: await reviewDiff(resolved.root, body.path, scopeOf(body.scope)) }); }
  catch (error) { return Response.json({ error: error instanceof Error ? error.message : String(error) }, { status: 400 }); }
}
