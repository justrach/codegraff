import { NextRequest } from "next/server";
import { resolveRoot } from "@/lib/server-root";
import { resolveInlineReference } from "@/lib/inline-reference";
export const runtime = "nodejs";
export const dynamic = "force-dynamic";
export async function GET(req: NextRequest) {
  const resolved = resolveRoot(req.nextUrl.searchParams.get("root"));
  if ("error" in resolved) return Response.json({ error: resolved.error }, { status: resolved.status });
  try { return Response.json(await resolveInlineReference(resolved.root, req.nextUrl.searchParams.get("path") ?? "")); }
  catch { return Response.json({ error: "Could not resolve this reference." }, { status: 400 }); }
}
