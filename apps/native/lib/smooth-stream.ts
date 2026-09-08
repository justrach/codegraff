type StreamScheduler = {
  now(): number; frame(callback: (now: number) => void): number; cancel(id: number): void;
};

/** Appending a target never restarts its pending frame; fast ACP delivery
 * must not continually postpone the visible reveal. Only the latest target is queued. */
export function createSmoothStream(initial: string, paint: (text: string) => void, scheduler: StreamScheduler = {
  now: () => performance.now(), frame: callback => requestAnimationFrame(callback), cancel: id => cancelAnimationFrame(id),
}) {
  let target = initial, shown = initial, frame: number | undefined, last = 0, generation = 0, closed = false;
  const cancel = () => {
    generation++;
    if (frame !== undefined) scheduler.cancel(frame);
    frame = undefined;
  };
  const schedule = () => {
    const ticket = generation;
    frame = scheduler.frame(now => {
      if (closed || ticket !== generation) return;
      frame = undefined;
      const dt = Math.max(0, Math.min(now - last, 80));
      last = now;
      const behind = target.length - shown.length;
      if (behind <= 0) return;
      const rate = Math.min(180 + behind * 1.4, 2800);
      let next = Math.min(target.length, shown.length + Math.max(1, Math.round(rate * dt / 1000)));
      if (next < target.length) {
        const cut = target.slice(next, next + 24).search(/\s/);
        if (cut > 0) next += cut + 1;
        // Never reveal half of a surrogate pair between frames.
        const previous = target.charCodeAt(next - 1);
        if (previous >= 0xd800 && previous <= 0xdbff) next++;
      }
      shown = target.slice(0, next);
      paint(shown);
      if (shown.length < target.length) schedule();
    });
  };
  return {
    update(next: string, live: boolean) {
      if (closed) return;
      target = next;
      if (!live || !target.startsWith(shown)) {
        cancel();
        if (shown !== target) { shown = target; paint(shown); }
        return;
      }
      if (frame === undefined && target !== shown) { last = scheduler.now(); schedule(); }
    },
    dispose() { cancel(); closed = true; target = ""; shown = ""; },
  };
}
