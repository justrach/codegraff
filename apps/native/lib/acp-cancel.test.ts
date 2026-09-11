import { test, expect } from 'bun:test';
import { finishCancelledPrompt } from './acp-cancel';
const deferred = () => { let resolve!: () => void; const promise = new Promise<void>(r => { resolve = r; }); return { promise, resolve }; };
test('cancel waits for the current prompt and preserves its reusable worker', async () => {
  const pending = deferred(); const slot = { pendingPrompt: pending.promise as Promise<unknown> | null, streaming: true };
  let expired = false;
  const cancel = finishCancelledPrompt(slot, () => { expired = true; }, 1000);
  expect(slot.streaming).toBe(true); pending.resolve(); await cancel;
  expect(slot.streaming).toBe(false); expect(slot.pendingPrompt).toBeNull(); expect(expired).toBe(false);
});
test('cancel retires a hung worker before releasing the prompt gate', async () => {
  const slot = { pendingPrompt: deferred().promise as Promise<unknown> | null, streaming: true };
  let expired = false;
  await finishCancelledPrompt(slot, () => { expect(slot.streaming).toBe(true); expired = true; }, 1);
  expect(expired).toBe(true); expect(slot.streaming).toBe(false);
});
test('a late cancellation does not clear the next prompt or retire its worker', async () => {
  const first = deferred(), second = deferred();
  const slot = { pendingPrompt: first.promise as Promise<unknown> | null, streaming: true };
  const cancel = finishCancelledPrompt(slot, () => { throw Error('wrong worker'); }, 1000);
  slot.pendingPrompt = second.promise; first.resolve(); await cancel;
  expect(slot.streaming).toBe(true); expect(slot.pendingPrompt).toBe(second.promise);
});
test('a rejected prompt releases the cancellation gate without waiting for the grace', async () => {
  const slot = { pendingPrompt: Promise.reject(Error('failed')) as Promise<unknown> | null, streaming: true };
  await finishCancelledPrompt(slot, () => { throw Error('already ended'); }, 1000);
  expect(slot.streaming).toBe(false);
});
test('a timeout keeps the gate closed until worker retirement completes', async () => {
  const stopped = deferred(), retiring = deferred();
  const slot = { pendingPrompt: deferred().promise as Promise<unknown> | null, streaming: true };
  const cancel = finishCancelledPrompt(slot, async () => { retiring.resolve(); await stopped.promise; }, 1);
  await retiring.promise; expect(slot.streaming).toBe(true);
  stopped.resolve(); await cancel; expect(slot.streaming).toBe(false);
});
