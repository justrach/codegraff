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

export function waitMs(ms: number, signal: AbortSignal): Promise<void> {
  return new Promise((resolve) => {
    if (signal.aborted || ms <= 0) {
      resolve();
      return;
    }
    const done = () => {
      clearTimeout(timer);
      signal.removeEventListener("abort", done);
      resolve();
    };
    const timer = setTimeout(done, ms);
    signal.addEventListener("abort", done, { once: true });
  });
}

/** Keep the idle pump open for the tab's lifetime. A dead ACP ends the
 *  stream; retry so `session/idle` can spawn it again instead of going
 *  silent until the next human prompt. */
export async function holdIdleUntilAbort(opts: {
  signal: AbortSignal;
  busy(): boolean;
  open(signal: AbortSignal): Promise<void>;
  pollMs?: number;
  retryDelayMs?: number;
}): Promise<void> {
  while (!opts.signal.aborted) {
    await waitWhile(() => opts.busy(), opts.signal, opts.pollMs);
    if (opts.signal.aborted) return;
    const result = await holdWhileIdle(opts);
    if (result === "aborted") return;
    if (result === "paused") continue;
    await waitMs(opts.retryDelayMs ?? 250, opts.signal);
  }
}
