type FrameScheduler = { frame(callback: () => void): number; cancel(id: number): void };

/** Keep only the newest pointer position until the next display frame. */
export function createFrameBatch<T>(paint: (value: T) => void, scheduler: FrameScheduler = {
  frame: callback => requestAnimationFrame(callback), cancel: id => cancelAnimationFrame(id),
}) {
  let frame: number | undefined, pending: { value: T } | undefined, generation = 0;
  const cancel = () => {
    generation++;
    if (frame !== undefined) scheduler.cancel(frame);
    frame = undefined; pending = undefined;
  };
  const flush = () => {
    const next = pending;
    cancel();
    if (next) paint(next.value);
  };
  return {
    update(value: T) {
      pending = { value };
      if (frame !== undefined) return;
      const ticket = generation;
      frame = scheduler.frame(() => { if (ticket === generation) flush(); });
    },
    flush,
    cancel,
  };
}
