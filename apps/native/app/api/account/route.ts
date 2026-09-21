import os from "node:os";
import { NextRequest } from "next/server";
import {
  clearApiKey,
  pollDeviceLogin,
  readAccountStatus,
  startDeviceLogin,
  storeApprovedKey,
} from "@/lib/codegraff-login";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

function homeDir(): string {
  return process.env.CODEGRAFF_HOME?.trim() || os.homedir();
}

function fail(error: unknown, status = 502): Response {
  return Response.json({ error: error instanceof Error ? error.message : String(error) }, { status });
}

export async function GET() {
  return Response.json(readAccountStatus(homeDir()));
}

export async function POST(req: NextRequest) {
  const body = await req.json().catch(() => ({})) as { action?: string; device_code?: string };
  const home = homeDir();
  try {
    if (body.action === "start") return Response.json(await startDeviceLogin());
    if (body.action === "poll") {
      const code = typeof body.device_code === "string" ? body.device_code.trim() : "";
      if (!code) return fail("device_code is required", 400);
      return Response.json(storeApprovedKey(home, await pollDeviceLogin(code)));
    }
    if (body.action === "logout") {
      clearApiKey(home);
      return Response.json(readAccountStatus(home));
    }
    return fail("unknown action", 400);
  } catch (error) {
    return fail(error);
  }
}
