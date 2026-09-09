import { describe, it } from "node:test";
import assert from "node:assert/strict";
import { createQueueSteerer, type SteerStatus } from "./prompt-queue-steer.ts";
import { enqueuePrompt, dropQueuedPrompt, prioritizeQueuedPrompt, shiftQueuedPrompt } from "./prompt-queue.ts";

function fixture(timeoutMs = 1000) {
  let queue = [1, 2, 3].map(id => ({ id, text: `message ${id}` }));
  let status: SteerStatus = {};
  const steerer = createQueueSteerer({ getQueue: () => queue, setQueue: (_, next) => { queue = next; }, status: (_, next) => { status = next; }, timeoutMs });
  steerer.begin(1);
  return { steerer, queue: () => queue, status: () => status, setQueue: (next: typeof queue) => { queue = next; } };
}

describe("queue force steer", () => {
  it("prioritizes before cancel and drains only the selected item", () => {
    const f = fixture();
    f.steerer.ready(1);
    let calls = 0;
    const cancel = async () => { calls++; assert.deepEqual(f.queue().map(x => x.id), [3, 1, 2]); };
    f.steerer.steer(1, 3, cancel);
    f.steerer.steer(1, 3, cancel);
    f.steerer.steer(1, 2, cancel);
    assert.equal(calls, 1);
    assert.equal(f.status().pending, 3);
    f.setQueue(enqueuePrompt(f.queue(), "four", 4));
    f.setQueue(dropQueuedPrompt(f.queue(), 2));
    f.steerer.finish(1);
    const { next, rest } = shiftQueuedPrompt(f.queue());
    assert.equal(next?.id, 3);
    assert.deepEqual(rest.map(x => x.id), [1, 4]);
  });

  it("preserves all entries on failure and allows retry", async () => {
    const f = fixture();
    f.steerer.ready(1);
    f.steerer.steer(1, 2, async () => { throw new Error("offline"); });
    await Promise.resolve();
    assert.match(f.status().error!, /still next/);
    assert.deepEqual(f.queue().map(x => x.id), [2, 1, 3]);
    let calls = 0;
    f.steerer.steer(1, 2, async () => { calls++; });
    assert.equal(calls, 1);
    f.steerer.finish(1);
  });

  it("waits for prompt readiness, but never cancels after that turn settles", () => {
    const f = fixture();
    let calls = 0;
    f.steerer.steer(1, 3, async () => { calls++; });
    assert.equal(calls, 0);
    assert.equal(f.queue()[0].id, 3);
    f.steerer.finish(1);
    f.steerer.begin(1);
    f.steerer.ready(1);
    assert.equal(calls, 0);
    f.steerer.finish(1);
  });

  it("dispatches a startup selection once the same turn becomes ready", () => {
    const f = fixture();
    let calls = 0;
    f.steerer.steer(1, 2, async () => { calls++; });
    f.steerer.ready(1);
    f.steerer.ready(1);
    assert.equal(calls, 1);
    f.steerer.finish(1);
  });

  it("ignores late cancellation failures from the previous turn", async () => {
    const f = fixture();
    let reject!: (error: Error) => void;
    f.steerer.ready(1);
    f.steerer.steer(1, 2, () => new Promise<void>((_, fail) => { reject = fail; }));
    f.steerer.finish(1);
    f.steerer.begin(1);
    reject(new Error("late"));
    await Promise.resolve();
    assert.deepEqual(f.status(), {});
    f.steerer.finish(1);
  });

  it("surfaces an unconfirmed cancellation without losing the queue", async () => {
    const f = fixture(5);
    f.steerer.ready(1);
    f.steerer.steer(1, 3, async () => {});
    await new Promise(resolve => setTimeout(resolve, 20));
    assert.match(f.status().error!, /Could not confirm/);
    assert.deepEqual(f.queue().map(x => x.id), [3, 1, 2]);
    f.steerer.finish(1);
  });

  it("ignores stale selections and leaves missing/head priorities unchanged", () => {
    const f = fixture();
    f.steerer.ready(1);
    f.steerer.steer(1, 99, async () => { assert.fail("must not cancel"); });
    assert.strictEqual(prioritizeQueuedPrompt(f.queue(), 99), f.queue());
    assert.strictEqual(prioritizeQueuedPrompt(f.queue(), 1), f.queue());
    assert.deepEqual(f.status(), {});
    f.steerer.finish(1);
  });
});
