import { test, expect } from "bun:test";
import { createFrameBatch } from "./frame-batch";

test("a pointer burst paints only its latest position on the display frame", () => {
  const frames: (() => void)[] = [], painted: number[] = [];
  const batch = createFrameBatch<number>(value => painted.push(value), {
    frame(callback) { frames.push(callback); return frames.length; }, cancel() {},
  });
  for (let frame = 0; frame < 120; frame++) {
    for (let event = 0; event < 8; event++) batch.update(frame * 8 + event);
    expect(frames.length).toBe(frame + 1);
    frames[frame]();
  }
  expect(painted).toEqual(Array.from({ length: 120 }, (_, frame) => frame * 8 + 7));
});

test("pointer release flushes its final position and a stale frame cannot overwrite the next drag", () => {
  const frames: (() => void)[] = [], painted: number[] = [];
  const batch = createFrameBatch<number>(value => painted.push(value), {
    frame(callback) { frames.push(callback); return frames.length; }, cancel() {},
  });
  batch.update(30); batch.update(40); batch.flush();
  batch.update(80); frames[0]();
  expect(painted).toEqual([40]);
  frames[1]();
  expect(painted).toEqual([40, 80]);
});

test("unmount cancels pending work without retaining a detached pane", () => {
  const frames: (() => void)[] = [], painted: unknown[] = [];
  const batch = createFrameBatch(value => painted.push(value), {
    frame(callback) { frames.push(callback); return frames.length; }, cancel() {},
  });
  batch.update({ pane: "detached" }); batch.cancel(); frames[0](); batch.flush();
  expect(painted).toEqual([]);
});
