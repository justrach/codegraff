import type { AcpTransport } from "./acp-transport";

/** A failed handshake cannot recover from a late reply. Retire its worker
 * before reporting failure so a retry starts with a fresh transport. */
export async function initializeWorker(
  transport: AcpTransport, cwd: string, retire: () => Promise<void>, timeoutMs: number,
): Promise<string> {
  let phase = "initialize";
  try {
    await transport.request(phase, { protocolVersion: 1, clientCapabilities: { fs: {} } }, timeoutMs);
    phase = "session/new";
    const created = await transport.request(phase, { cwd }, timeoutMs) as { sessionId?: unknown } | null;
    if (typeof created?.sessionId !== "string" || !created.sessionId) {
      throw new Error("session/new returned no sessionId");
    }
    return created.sessionId;
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
