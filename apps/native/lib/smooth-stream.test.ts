import { test, expect } from "bun:test";
import { createSmoothStream } from "./smooth-stream";

function fixture(initial = "") {
  let now = 0;
  const frames: ((now: number) => void)[] = [], painted: string[] = [];
  const stream = createSmoothStream(initial, text => painted.push(text), {
    now: () => now, frame(callback) { frames.push(callback); return frames.length; }, cancel() {},
  });
  return { stream, frames, painted, tick(index: number) { now += 1000 / 120; frames[index](now); } };
}

test("a remounted chat reveals only content added after the last visit", () => {
  const received = "An answer already received before switching tabs. ".repeat(20);
  const first = fixture();
  first.stream.update(received, true);
  first.tick(0);
  expect(first.painted.at(-1)?.length).toBeLessThan(received.length);
  first.stream.dispose();

  // Unmount records all text received in the visible chat, including the
  // queued tail. A second mount with unchanged content schedules no reveal.
  const returnVisit = fixture(received);
  returnVisit.stream.update(received, true);
  expect(returnVisit.frames).toHaveLength(0);
  const next = `${received}One new line arrived while away.`;
  returnVisit.stream.update(next, true);
  expect(returnVisit.frames).toHaveLength(1);
  returnVisit.tick(0);
  expect(returnVisit.painted.at(-1)?.startsWith(received)).toBe(true);
  returnVisit.stream.dispose();

  const again = fixture(next);
  again.stream.update(next, true);
  expect(again.frames).toHaveLength(0);
  again.stream.dispose();
});

test("starting on the full string never typewrites — the live hook must start empty", () => {
  const painted: string[] = [];
  const frames: ((now: number) => void)[] = [];
  let now = 0;
  const blob = "The whole answer arrives in one chunk. ".repeat(20);
  const stream = createSmoothStream(blob, text => painted.push(text), {
    now: () => now, frame(callback) { frames.push(callback); return frames.length; }, cancel() {},
  });
  stream.update(blob, true);
  expect(frames.length).toBe(0);
  expect(painted).toEqual([]);
  stream.dispose();
});

test("an empty start reveals the first live chunk instead of painting it in", () => {
  const { stream, frames, painted, tick } = fixture();
  const blob = "The whole answer arrives in one chunk. ".repeat(20);
  stream.update(blob, true);
  expect(frames.length).toBe(1);
  tick(0);
  expect(painted.at(-1)?.length).toBeGreaterThan(0);
  expect(painted.at(-1)?.length).toBeLessThan(blob.length);
  stream.dispose();
});

test("120 Hz deliveries update the pending reveal instead of cancelling it", () => {
  const { stream, frames, painted, tick } = fixture();
  let target = "";
  for (let frame = 0; frame < 120; frame++) {
    for (let event = 0; event < 4; event++) { target += "More useful text. "; stream.update(target, true); }
    expect(frames.length).toBe(frame + 1);
    tick(frame);
  }
  expect(painted.length).toBe(120);
  expect(painted.every((text, index) => target.startsWith(text) && (!index || text.length > painted[index - 1].length))).toBe(true);
  stream.update(target, false);
  expect(painted.at(-1)).toBe(target);
});

test("completion and replacement invalidate old frames without overwriting final text", () => {
  const { stream, frames, painted, tick } = fixture();
  stream.update("A long response ".repeat(100), true); tick(0);
  stream.update("Replacement", true); frames[1](25);
  expect(painted.at(-1)).toBe("Replacement");
  stream.update("Replacement grows into a new answer ".repeat(10), true);
  stream.update("Finished answer", false); frames[2](30);
  expect(painted.at(-1)).toBe("Finished answer");
});

test("reveal never publishes broken Unicode and disposal stops pending callbacks", () => {
  const { stream, frames, painted, tick } = fixture();
  stream.update("😀".repeat(100), true);
  for (let index = 0; index < 20; index++) tick(index);
  expect(painted.every(text => text.length % 2 === 0 && text.isWellFormed())).toBe(true);
  const count = painted.length;
  stream.dispose(); frames.at(-1)?.(200); stream.update("late", false);
  expect(painted.length).toBe(count);
});

test("disabling motion flushes queued text and resuming only reveals future updates", () => {
  const { stream, frames, painted, tick } = fixture();
  const first = "A live answer with queued words. ".repeat(30);
  stream.update(first, true); tick(0);
  const pending = frames.length;
  stream.update(first, false);
  expect(painted.at(-1)).toBe(first);
  frames.at(-1)?.(30);
  expect(painted.at(-1)).toBe(first);
  const latest = `${first}Content received while motion is off. `;
  stream.update(latest, false);
  expect(painted.at(-1)).toBe(latest);
  expect(frames.length).toBe(pending);
  stream.update(latest, true);
  expect(frames.length).toBe(pending);
  const next = `${latest}Only this new content needs a reveal. `.repeat(2);
  stream.update(next, true);
  expect(frames.length).toBe(pending + 1);
  tick(pending);
  expect(painted.at(-1)?.startsWith(latest)).toBe(true);
  expect(painted.at(-1)?.length).toBeGreaterThan(latest.length);
  stream.dispose();
});
