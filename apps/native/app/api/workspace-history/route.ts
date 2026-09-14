import { NextRequest } from "next/server";
import { discoverWorkspaceHistory } from "@/lib/workspace-history";
import { defaultRoot } from "@/lib/server-root";
export const runtime = "nodejs";
export const dynamic = "force-dynamic";
export async function GET(req: NextRequest) {
  return Response.json({ workspaces: discoverWorkspaceHistory([defaultRoot(), ...req.nextUrl.searchParams.getAll("root").slice(0, 50)]) });
}
