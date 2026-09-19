/** Long-lived idle fetches must yield the HTTP/1.1 slot when a turn starts.
 *  Chromium caps six connections per origin; a split of prompt streams plus
 *  idle SSE saturates it and `/api/attach` never starts (#1068). */

export type IdleHoldResult = "paused" | "ended" | "aborted";

export function waitWhile(busy: () => boolean, signal: AbortSignal, stepMs = 50): Promise<void> {
  return new Promise((resolve) => {
    if (!busy() || signal.aborted) {
      resolve();
      return;
    }
    const tick = () => {
      if (!busy() || signal.aborted) {
        clearInterval(id);
        signal.removeEventListener("abort", stop);
        resolve();
      }
    };
    const stop = () => tick();
    const id = setInterval(tick, stepMs);
    signal.addEventListener("abort", stop, { once: true });
  });
}

/** Run `open` until it ends, the caller aborts, or `busy` becomes true. */
export async function holdWhileIdle(opts: {
  signal: AbortSignal;
  busy(): boolean;
  open(signal: AbortSignal): Promise<void>;
  pollMs?: number;
}): Promise<IdleHoldResult> {
  if (opts.signal.aborted) return "aborted";
  if (opts.busy()) return "paused";
  const hold = new AbortController();
  const stop = () => hold.abort();
  opts.signal.addEventListener("abort", stop, { once: true });
  const poll = setInterval(() => {
    if (opts.busy()) hold.abort();
  }, opts.pollMs ?? 50);
  try {
    await opts.open(hold.signal);
  } catch {
    /* caller maps abort / stream errors to the result below */
  } finally {
    clearInterval(poll);
    opts.signal.removeEventListener("abort", stop);
  }
  if (opts.signal.aborted) return "aborted";
  if (opts.busy() || hold.signal.aborted) return "paused";
  return "ended";
}
