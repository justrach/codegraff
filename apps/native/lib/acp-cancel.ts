type TurnSlot = { pendingPrompt: Promise<unknown> | null; streaming: boolean };

/** A cancellation owns one prompt. Its late completion must not release another. */
export async function finishCancelledPrompt(slot: TurnSlot, expire: () => void | Promise<void>, graceMs: number) {
  const pending = slot.pendingPrompt;
  if (!pending) return;
  let timer: ReturnType<typeof setTimeout> | undefined;
  const settled = await Promise.race([
    pending.then(() => true, () => true),
    new Promise<false>(resolve => { timer = setTimeout(() => resolve(false), graceMs); }),
  ]).finally(() => clearTimeout(timer));
  if (slot.pendingPrompt !== pending) return;
  // A stuck worker cannot safely accept another prompt or keep broadcasting
  // updates into its successor. Retire its transport before reopening the gate.
  if (!settled) await expire();
  if (slot.pendingPrompt === pending) { slot.pendingPrompt = null; slot.streaming = false; }
}
