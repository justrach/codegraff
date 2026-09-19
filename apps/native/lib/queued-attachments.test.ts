import { test } from "node:test";
import assert from "node:assert/strict";
import { splitImageMarkers, withAttachmentMarkers } from "./attachments.ts";
import { enqueuePrompt, shiftQueuedPrompt } from "./prompt-queue.ts";
import { holdWhileIdle } from "./idle-http.ts";

const staged = "/tmp/qa/graff-native-attachments/uuid-shot.png";
const shot = { id: staged, name: "shot.png", path: staged };

test("a queued follow-up carries its attachment markers like an immediate send", () => {
  // Busy send: the composer appends markers, the harness enqueues the text,
  // and the drain hands that same text to the queued run.
  const queued = enqueuePrompt([], withAttachmentMarkers("look at this", [shot]), 1);
  assert.equal(queued[0]?.text, `look at this @[${staged}]`);
  const { next, rest } = shiftQueuedPrompt(queued);
  assert.equal(next?.text, `look at this @[${staged}]`);
  assert.deepEqual(rest, []);
});

test("the queued row still finds the staged image behind the marker", () => {
  const { next } = shiftQueuedPrompt(enqueuePrompt([], withAttachmentMarkers("compare", [shot]), 1));
  const markers = splitImageMarkers(next?.text ?? "").filter((_, index) => index % 2 === 1);
  assert.deepEqual(markers, [`@[${staged}]`]);
});

test("every chat's idle stream drops while any turn runs", async () => {
  // Two chats share one running set, as the harness passes it: chat B's idle
  // hold must drop when chat A's turn starts, freeing B's pool slot for A's
  // mid-turn attach, and reopen once nothing runs.
  const running = new Set<number>();
  const busy = () => running.size > 0;
  const hang = (stream: AbortSignal, onAbort: () => void) =>
    new Promise<void>((_, reject) => {
      stream.addEventListener("abort", () => {
        onAbort();
        reject(new DOMException("aborted", "AbortError"));
      }, { once: true });
    });

  const ac = new AbortController();
  let dropped = 0;
  const waiting = holdWhileIdle({ signal: ac.signal, busy, pollMs: 10, open: (stream) => hang(stream, () => { dropped += 1; }) });
  await new Promise((resolve) => setTimeout(resolve, 15));
  running.add(1); // chat A's turn starts; B's idle stream must go.
  assert.equal(await waiting, "paused");
  assert.equal(dropped, 1);

  running.delete(1);
  const ac2 = new AbortController();
  let opened = 0;
  const idle = holdWhileIdle({
    signal: ac2.signal,
    busy,
    pollMs: 10,
    open: (stream) => {
      opened += 1;
      return hang(stream, () => {});
    },
  });
  await new Promise((resolve) => setTimeout(resolve, 15));
  assert.equal(opened, 1);
  ac2.abort();
  assert.equal(await idle, "aborted");
});
