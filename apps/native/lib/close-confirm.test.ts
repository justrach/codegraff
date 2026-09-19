import { test } from "node:test";
import assert from "node:assert/strict";
import { CLOSE_DONT_ASK_KEY, closeWorkerCount, parseCloseDontAsk, readCloseDontAsk, shouldConfirmTabClose, writeCloseDontAsk } from "./close-confirm.ts";

function memoryStorage(entries: Record<string, string> = {}) {
  const store = new Map(Object.entries(entries));
  return {
    getItem: (key: string) => (store.has(key) ? store.get(key)! : null),
    setItem: (key: string, value: string) => { store.set(key, value); },
  };
}

function throwingStorage() {
  return {
    getItem: (_key: string): string | null => { throw new Error("storage unavailable"); },
    setItem: (_key: string, _value: string) => { throw new Error("storage unavailable"); },
  };
}

test("the stored choice parses the true forms and nothing else", () => {
  assert.equal(parseCloseDontAsk(true), true);
  assert.equal(parseCloseDontAsk("true"), true);
  assert.equal(parseCloseDontAsk("1"), true);
  assert.equal(parseCloseDontAsk(false), false);
  assert.equal(parseCloseDontAsk("false"), false);
  assert.equal(parseCloseDontAsk("0"), false);
  assert.equal(parseCloseDontAsk(null), false);
  assert.equal(parseCloseDontAsk(undefined), false);
  assert.equal(parseCloseDontAsk("yes"), false);
});

test("a fresh profile asks; a remembered choice never does", () => {
  assert.equal(shouldConfirmTabClose({ dontAskAgain: false, closingWorkers: 1 }), true);
  assert.equal(shouldConfirmTabClose({ dontAskAgain: false, closingWorkers: 3 }), true);
  assert.equal(shouldConfirmTabClose({ dontAskAgain: true, closingWorkers: 1 }), false);
  assert.equal(shouldConfirmTabClose({ dontAskAgain: true, closingWorkers: 3 }), false);
});

test("tabs without a worker close silently even while the prompt is armed", () => {
  assert.equal(shouldConfirmTabClose({ dontAskAgain: false, closingWorkers: 0 }), false);
  assert.equal(shouldConfirmTabClose({ dontAskAgain: true, closingWorkers: 0 }), false);
});

test("only tabs with a live worker count toward the prompt", () => {
  const live = new Set([2, 5]);
  assert.equal(closeWorkerCount([1], (id) => live.has(id)), 0);
  assert.equal(closeWorkerCount([2], (id) => live.has(id)), 1);
  assert.equal(closeWorkerCount([1, 2, 5], (id) => live.has(id)), 2);
  assert.equal(closeWorkerCount([], (id) => live.has(id)), 0);
});

test("the choice round-trips through storage under its own key", () => {
  const storage = memoryStorage();
  assert.equal(readCloseDontAsk(storage), false);
  writeCloseDontAsk(storage, true);
  assert.equal(storage.getItem(CLOSE_DONT_ASK_KEY), "true");
  assert.equal(readCloseDontAsk(storage), true);
  writeCloseDontAsk(storage, false);
  assert.equal(readCloseDontAsk(storage), false);
});

test("unavailable storage asks every time instead of throwing", () => {
  assert.equal(readCloseDontAsk(throwingStorage()), false);
  assert.equal(readCloseDontAsk(null), false);
  assert.equal(readCloseDontAsk(undefined), false);
  assert.doesNotThrow(() => writeCloseDontAsk(throwingStorage(), true));
  assert.doesNotThrow(() => writeCloseDontAsk(null, true));
});
