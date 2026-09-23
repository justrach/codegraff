/** ACP paints `announceTransientRetry` as one `agent_message_chunk`.
 * Match the whole chunk (trimmed), not a substring, so quoted prose still appends. */
const TRANSIENT_RETRY =
  /^\[(?:provider error mid-response|server overloaded) — retrying in \d+s \(\d+\/3\)\]$/;

/** Inner notice for TurnActivity, or null when the chunk is ordinary prose. */
export function transientRetryNotice(text: string): string | null {
  const line = text.trim();
  return (TRANSIENT_RETRY.test(line) || /^\[network error: [A-Za-z0-9_]+ — retrying in \d+ms \(\d+\/\d+\)\]$/.test(line)) ? line.slice(1, -1) : null;
}
