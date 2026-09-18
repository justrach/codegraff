import { NextRequest } from "next/server";
import {
  attachChatTab,
  checkBearer,
  extensionCall,
  extensionPoll,
  extensionResult,
  extensionPin,
  extensionStatus,
} from "@/lib/extension-bridge";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

/** The Chrome extension's endpoint. The extension phones out — long-polls
 * here for commands, POSTs results back — so the harness holds no pages
 * and opens no socket for it. Bearer pairing token, loopback by deployment
 * (the Next server binds 127.0.0.1); bypasses proxy.ts, which would demand
 * the desktop header the extension cannot send.
 *
 * Body shapes:
 *   { type: "poll", extId, tabs } -> { command } (at most one; null idle)
 *   { type: "result", id, ok, result?, error? } -> { ok: true }
 *   { type: "event", event: "pin", pin } -> { ok: true }
 * Long-poll: held up to 25 s when idle so polls arrive instantly on demand.
 */

const HOLD_MS = 25_000;

export async function GET(req: NextRequest) {
  if (!checkBearer(req.headers.get("authorization"))) return Response.json({ error: "Unauthorized" }, { status: 401 });
  return Response.json(extensionStatus());
}

export async function POST(req: NextRequest) {
  if (!checkBearer(req.headers.get("authorization"))) return Response.json({ error: "Unauthorized" }, { status: 401 });
  let body: Record<string, unknown>;
  try {
    body = (await req.json()) as Record<string, unknown>;
  } catch {
    return Response.json({ error: "expected JSON" }, { status: 400 });
  }
  const type = body.type;
  if (type === "poll") {
    const extId = typeof body.extId === "string" ? body.extId : "unknown";
    const tabs = Array.isArray(body.tabs) ? body.tabs : [];
    const fast = extensionPoll(extId, tabs);
    if (fast) return Response.json({ command: fast });
    // Hold the poll so a command queued a second later runs now, not on
    // the next heartbeat. The extension's fetch has no AbortSignal timeout
    // of its own; 25 s is well under server/request timeouts.
    const deadline = Date.now() + HOLD_MS;
    while (Date.now() < deadline) {
      await new Promise((r) => setTimeout(r, 500));
      const command = extensionPoll(extId, Array.isArray(body.tabs) ? body.tabs : []);
      if (command) return Response.json({ command });
      // The extension re-polls on its own cadence; a second poller means
      // the tab list went stale mid-hold, so hand back nothing.
      if (Date.now() - (extensionStatus().lastPollMs ?? 0) > HOLD_MS + 5_000) break;
    }
    return Response.json({ command: null });
  }
  if (type === "result") {
    if (typeof body.id !== "string") return Response.json({ error: "missing id" }, { status: 400 });
    extensionResult(body.id, body.ok === true, body.result ?? null, typeof body.error === "string" ? body.error : "");
    return Response.json({ ok: true });
  }
  if (type === "event") {
    if (body.event === "pin" && body.pin && typeof body.pin === "object") {
      extensionPin(body.pin as Parameters<typeof extensionPin>[0]);
      return Response.json({ ok: true });
    }
    return Response.json({ error: "unknown event" }, { status: 400 });
  }
  if (type === "attach" && typeof body.chat === "string" && Number.isFinite(Number(body.tabId))) {
    attachChatTab(body.chat, Number(body.tabId));
    return Response.json({ ok: true });
  }
  // The pane's own calls (same origin, no Bearer): forward one method to
  // the paired tab and wait for the result. The pairing token never
  // leaves the server; the pane only names the method.
  if (typeof type === "string" && !body.extId && typeof body.chat === "string") {
    try {
      const result = await extensionCall(body.chat, type, (body.params as Record<string, unknown>) ?? {});
      return Response.json({ result });
    } catch (err) {
      return Response.json({ error: err instanceof Error ? err.message : String(err) }, { status: 502 });
    }
  }
  return Response.json({ error: "unknown type" }, { status: 400 });
}
