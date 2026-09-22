import { realpathSync } from "node:fs";
import path from "node:path";
import type { AcpTransport } from "./acp-transport";

function sameDir(left: string, right: string): boolean {
  if (left === right) return true;
  try { return realpathSync(left) === realpathSync(right); } catch { return false; }
}

/** Keep the spawn workspace unless session/new named a real absolute checkout
 * that is not the host process cwd. A relative "." (g_cwd_display default) or
 * inherited PWD from `next start` in apps/native would otherwise enroll
 * `apps/native/.graff/sessions` instead of the fixture workspace. Isolated
 * worktrees stay adopted. Host aliases (`/var` vs `/private/var`) stay host. */
export function bindSessionCwd(requested: string, reported?: string, hostCwd = process.cwd()): string {
  if (!reported) return requested;
  const checkout = reported.trim();
  if (!checkout || !path.isAbsolute(checkout)) return requested;
  const resolved = path.resolve(checkout);
  const spawned = path.resolve(requested);
  const host = path.resolve(hostCwd);
  if (sameDir(resolved, host) && !sameDir(resolved, spawned)) return requested;
  return resolved;
}

/** A failed handshake cannot recover from a late reply. Retire its worker
 * before reporting failure so a retry starts with a fresh transport. */
export async function initializeWorker(
  transport: AcpTransport, cwd: string, retire: () => Promise<void>, timeoutMs: number,
): Promise<{ sessionId: string; cwd?: string }> {
  let phase = "initialize";
  try {
    const initialized = await transport.request(phase, { protocolVersion: 1, clientCapabilities: { fs: {} } }, timeoutMs) as { protocolVersion?: unknown } | null;
    if (initialized?.protocolVersion !== 1) {
      throw new Error("initialize returned an unsupported or missing protocolVersion; expected 1");
    }
    phase = "session/new";
    const created = await transport.request(phase, { cwd, mcpServers: [] }, timeoutMs) as { sessionId?: unknown; cwd?: unknown } | null;
    if (typeof created?.sessionId !== "string" || !created.sessionId) {
      throw new Error("session/new returned no sessionId");
    }
    const checkout = typeof created.cwd === "string" && created.cwd.trim() ? created.cwd.trim() : undefined;
    return checkout ? { sessionId: created.sessionId, cwd: checkout } : { sessionId: created.sessionId };
  } catch (cause) {
    const detail = cause instanceof Error ? cause.message : String(cause);
    const error = new Error(`ACP startup failed during ${phase}: ${detail}. Retry to start a new worker.`, { cause });
    transport.abort(error);
    try { await retire(); }
    catch (cleanup) { throw new Error(`${error.message} Worker cleanup failed: ${cleanup instanceof Error ? cleanup.message : String(cleanup)}`, { cause: error }); }
    throw error;
  }
}

/** Serialize a chat's handshakes, then re-evaluate its live slot/options.
 * A failed or disposed startup rejects its already queued callers too; only
 * a later explicit request retries. Different chats remain independent. */
export async function serializeBootstrap<T>(
  pending: Map<string, Promise<T>>, chat: string, start: () => Promise<T>,
): Promise<T> {
  const previous = pending.get(chat);
  const next = previous ? previous.then(start) : Promise.resolve().then(start);
  pending.set(chat, next);
  try { return await next; }
  finally { if (pending.get(chat) === next) pending.delete(chat); }
}
