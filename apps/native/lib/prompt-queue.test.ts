import { describe, it } from "node:test";
import assert from "node:assert/strict";
import { dropQueuedPrompt, editQueuedPrompt, enqueuePrompt, prioritizeQueuedPrompt, setQueuedPromptEditing, shiftQueuedPrompt } from "./prompt-queue.ts";

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

  it("prioritizes a selected follow-up without dropping the others", () => {
    const list = [{ id: 1, text: "a" }, { id: 2, text: "b" }, { id: 3, text: "c" }];
    assert.deepEqual(prioritizeQueuedPrompt(list, 3).map(item => item.id), [3, 1, 2]);
    assert.strictEqual(prioritizeQueuedPrompt(list, 1), list);
  });

  it("edits one entry in place, keeping every id and the order", () => {
    const list = [{ id: 1, text: "a" }, { id: 2, text: "b" }, { id: 3, text: "c" }];
    assert.deepEqual(editQueuedPrompt(list, 2, "  b, reworded  "), [
      { id: 1, text: "a" },
      { id: 2, text: "b, reworded" },
      { id: 3, text: "c" },
    ]);
  });

  it("keeps an attachment marker in the edited text, which is what goes on the wire", () => {
    const list = [{ id: 1, text: "first" }];
    const edited = "look @[/tmp/x/graff-native-attachments/shot.png]";
    assert.deepEqual(editQueuedPrompt(list, 1, edited), [{ id: 1, text: edited }]);
  });

  it("an edit that leaves nothing behind drops the entry, the same result as its ✕", () => {
    const list = [{ id: 1, text: "a" }, { id: 2, text: "b" }];
    assert.deepEqual(editQueuedPrompt(list, 1, "   \n "), [{ id: 2, text: "b" }]);
  });

  it("editing an id that is not queued changes nothing", () => {
    const list = [{ id: 1, text: "a" }];
    assert.strictEqual(editQueuedPrompt(list, 99, "b"), list);
  });
});


describe("queue editing lifecycle", () => {
  const list = [{ id: 1, text: "first" }, { id: 2, text: "original" }];
  it("holds the entire queue while a non-head entry is being edited", () => {
    const held = setQueuedPromptEditing(list, 2, true);
    assert.deepEqual(shiftQueuedPrompt(held), { next: undefined, rest: held });
    const saved = editQueuedPrompt(held, 2, "updated\n@[/tmp/graff-native-attachments/a.png]");
    const { next, rest } = shiftQueuedPrompt(saved);
    assert.equal(next?.text, "first");
    assert.equal(shiftQueuedPrompt(rest).next?.text, "updated\n@[/tmp/graff-native-attachments/a.png]");
  });
  it("cancelling releases the hold without changing text or order", () => {
    const resumed = setQueuedPromptEditing(setQueuedPromptEditing(list, 2, true), 2, false);
    assert.deepEqual(resumed, list);
    assert.equal(shiftQueuedPrompt(resumed).next?.id, 1);
  });
  it("removing the edited entry releases the queue and late edits cannot recreate it", () => {
    const remaining = dropQueuedPrompt(setQueuedPromptEditing(list, 2, true), 2);
    assert.equal(shiftQueuedPrompt(remaining).next?.id, 1);
    assert.deepEqual(editQueuedPrompt(remaining, 2, "late save"), remaining);
    assert.deepEqual(setQueuedPromptEditing([], 2, false), []);
  });
});
