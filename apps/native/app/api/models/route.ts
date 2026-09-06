import { NextRequest } from "next/server";
import { resolveRoot } from "@/lib/server-root";
import { readModelCatalog } from "@/lib/model-catalog-server";
export const runtime = "nodejs";
export const dynamic = "force-dynamic";
export async function GET(req: NextRequest) {
  const resolved = resolveRoot(req.nextUrl.searchParams.get("root"));
  if ("error" in resolved) return Response.json({ error: resolved.error }, { status: resolved.status });
  try { return Response.json({ result: await readModelCatalog(resolved.root) }); }
  catch (error) { return Response.json({ error: error instanceof Error ? error.message : String(error) }, { status: 502 }); }
}
