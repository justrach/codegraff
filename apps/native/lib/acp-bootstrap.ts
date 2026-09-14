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
