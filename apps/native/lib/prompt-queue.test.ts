import { describe, it } from "node:test";
import assert from "node:assert/strict";
import { dropQueuedPrompt, enqueuePrompt, shiftQueuedPrompt } from "./prompt-queue.ts";

describe("prompt-queue", () => {
  it("ignores blank lines", () => {
    assert.deepEqual(enqueuePrompt([], "   \n", 1), []);
  });

  it("queues, drops, and drains in order", () => {
    let list = enqueuePrompt([], " first ", 1);
    list = enqueuePrompt(list, "second", 2);
    assert.deepEqual(list, [
      { id: 1, text: "first" },
      { id: 2, text: "second" },
    ]);
    list = dropQueuedPrompt(list, 1);
    const { next, rest } = shiftQueuedPrompt(list);
    assert.deepEqual(next, { id: 2, text: "second" });
    assert.deepEqual(rest, []);
  });
});
