type Scheduler = { frame(callback: () => void): number; cancelFrame(id: number): void; delay(callback: () => void): ReturnType<typeof setTimeout>; cancelDelay(id: ReturnType<typeof setTimeout>): void };
export function createTurnPainter<T>(paint: (value: T) => void, scheduler: Scheduler = {
  frame: callback => requestAnimationFrame(callback), cancelFrame: id => cancelAnimationFrame(id),
  delay: callback => setTimeout(callback, 100), cancelDelay: id => clearTimeout(id),
}) {
  let frame: number | undefined, timer: ReturnType<typeof setTimeout> | undefined, latest: T, generation = 0, closed = false;
  const cancel = () => { generation++; if (frame !== undefined) scheduler.cancelFrame(frame); if (timer !== undefined) scheduler.cancelDelay(timer); frame = undefined; timer = undefined; };
  return {
    update(value: T) {
      if (closed) return;
      latest = value; if (frame !== undefined || timer !== undefined) return;
      const ticket = generation;
      const commit = () => { if (closed || ticket !== generation) return; cancel(); paint(latest); };
      frame = scheduler.frame(commit); timer = scheduler.delay(commit);
    },
    finish(value: T) { if (closed) return; cancel(); closed = true; paint(value); },
    dispose() { cancel(); closed = true; },
  };
}
