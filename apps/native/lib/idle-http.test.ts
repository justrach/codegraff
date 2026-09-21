import { test } from "node:test";
import assert from "node:assert/strict";
import { holdIdleUntilAbort, holdWhileIdle, waitWhile } from "./idle-http.ts";

test("waitWhile returns immediately when idle", async () => {
  const ac = new AbortController();
  await waitWhile(() => false, ac.signal);
  assert.equal(ac.signal.aborted, false);
});

test("waitWhile yields once busy clears", async () => {
  const ac = new AbortController();
  let busy = true;
  const waited = waitWhile(() => busy, ac.signal, 10);
  setTimeout(() => {
    busy = false;
  }, 25);
  await waited;
  assert.equal(busy, false);
});

test("holdWhileIdle aborts the open stream when a turn starts", async () => {
  const ac = new AbortController();
  let busy = false;
  let opened = 0;
  let aborted = false;
  const held = holdWhileIdle({
    signal: ac.signal,
    busy: () => busy,
    pollMs: 10,
    open: (signal) => new Promise((_, reject) => {
      opened += 1;
      signal.addEventListener("abort", () => {
        aborted = true;
        reject(new DOMException("aborted", "AbortError"));
      }, { once: true });
    }),
  });
  await new Promise((resolve) => setTimeout(resolve, 15));
  assert.equal(opened, 1);
  busy = true;
  assert.equal(await held, "paused");
  assert.equal(aborted, true);
});

test("holdWhileIdle reports ended when the stream finishes while idle", async () => {
  const ac = new AbortController();
  assert.equal(await holdWhileIdle({
    signal: ac.signal,
    busy: () => false,
    open: async () => {},
  }), "ended");
});

test("holdIdleUntilAbort reopens after a dead ACP ends the stream", async () => {
  const ac = new AbortController();
  let opened = 0;
  const pumping = holdIdleUntilAbort({
    signal: ac.signal,
    busy: () => false,
    retryDelayMs: 10,
    pollMs: 10,
    open: async () => {
      opened += 1;
      if (opened >= 2) ac.abort();
    },
  });
  await pumping;
  assert.ok(opened >= 2);
});
