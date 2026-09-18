import { readFile } from "node:fs/promises";
import path from "node:path";
import { NextRequest } from "next/server";
import { resolveRoot } from "@/lib/server-root";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

export type ClaimRow = { kind: string; key: string; session: string; pid: number };

export async function GET(req: NextRequest) {
  const resolved = resolveRoot(req.nextUrl.searchParams.get("root"));
  if ("error" in resolved) return Response.json({ error: resolved.error }, { status: resolved.status });
  try {
    const text = await readFile(path.join(resolved.root, ".graff", "artifact-claims.json"), "utf8");
    const parsed = JSON.parse(text) as unknown;
    const claims: ClaimRow[] = Array.isArray(parsed) ? parsed.flatMap((item) => {
      if (!item || typeof item !== "object") return [];
      const rec = item as { kind?: unknown; key?: unknown; session?: unknown; pid?: unknown };
      if (typeof rec.kind !== "string" || typeof rec.key !== "string" || typeof rec.session !== "string") return [];
      return [{ kind: rec.kind, key: rec.key, session: rec.session, pid: typeof rec.pid === "number" ? rec.pid : 0 }];
    }) : [];
    return Response.json({ ok: true, claims });
  } catch (error) {
    const code = error && typeof error === "object" && "code" in error ? (error as { code?: string }).code : "";
    if (code === "ENOENT") return Response.json({ ok: true, claims: [] });
    return Response.json({ error: error instanceof Error ? error.message : String(error) }, { status: 500 });
  }
}
