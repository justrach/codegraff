import { test } from "node:test";
import assert from "node:assert/strict";
import { resumeQueuedPrompt } from "./prompt-queue-resume.ts";
import { setQueuedPromptEditing, shiftQueuedPrompt, type QueuedPrompt } from "./prompt-queue.ts";

function fixture() {
  let finishSettings!: () => void;
  const settings = new Promise<void>(resolve => { finishSettings = resolve; });
  let queue: QueuedPrompt[] = [{ id: 1, text: "queued follow-up" }];
  let active = false, open = true, settingsDone = false;
  const sent: string[] = [], pending = new Set<number>();
  const options = {
    pending,
    canStart: () => open && !active,
    wait: () => settings,
    take: () => { const { next, rest } = shiftQueuedPrompt(queue); queue = rest; return next; },
    run: (_chat: number, text: string) => { assert.equal(settingsDone, true); active = true; sent.push(text); },
  };
  return {
    options, sent, queue: () => queue,
    completeSettings: () => { settingsDone = true; finishSettings(); },
    hold: () => { queue = setQueuedPromptEditing(queue, 1, true); },
    close: () => { open = false; queue = []; },
    beginAnotherTurn: () => { active = true; },
  };
}

test("queue resumption waits for settings without dequeuing or starting duplicate prompts", async () => {
  const f = fixture();
  const resumed = resumeQueuedPrompt(1, f.options);
  await resumeQueuedPrompt(1, f.options);
  assert.equal(f.queue().length, 1);
  assert.deepEqual(f.sent, []);
  f.completeSettings();
  await resumed;
  assert.deepEqual(f.sent, ["queued follow-up"]);
  assert.deepEqual(f.queue(), []);
  assert.equal(f.options.pending.size, 0);
});

test("an edit opened during settings keeps its prompt queued after settings finish", async () => {
  const f = fixture();
  const resumed = resumeQueuedPrompt(1, f.options);
  f.hold();
  f.completeSettings();
  await resumed;
  assert.deepEqual(f.sent, []);
  assert.equal(f.queue().length, 1);
  assert.equal(f.options.pending.size, 0);
});

test("resumption rechecks closed chats and a newer active turn before dequeue", async () => {
  for (const state of ["close", "running"]) {
    const f = fixture();
    const resumed = resumeQueuedPrompt(1, f.options);
    state === "close" ? f.close() : f.beginAnotherTurn();
    f.completeSettings();
    await resumed;
    assert.deepEqual(f.sent, []);
    assert.equal(f.queue().length, state === "close" ? 0 : 1);
    assert.equal(f.options.pending.size, 0);
  }
});
