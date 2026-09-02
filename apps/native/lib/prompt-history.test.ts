import { test } from "node:test";
import assert from "node:assert/strict";
import {
  HISTORY_KEY,
  entryAt,
  historyKeyIntent,
  loadHistory,
  mergeHistory,
  pushHistory,
  saveHistory,
  stepHistory,
} from "./prompt-history.ts";

test("pushHistory appends, moves a repeat to the newest slot, and caps from the old end", () => {
  assert.deepEqual(pushHistory([], "  hi  "), ["hi"]);
  assert.deepEqual(pushHistory(["a", "b"], "a"), ["b", "a"]);
  assert.deepEqual(pushHistory(["a", "b"], "b"), ["a", "b"]);
  assert.deepEqual(pushHistory(["a", "b"], "   "), ["a", "b"]);
  assert.deepEqual(pushHistory(["a", "b", "c"], "d", 3), ["b", "c", "d"]);
});

test("mergeHistory keeps each prompt once at its most recent position", () => {
  assert.deepEqual(mergeHistory(["old", "x", "y"], ["x", "z"]), ["old", "y", "x", "z"]);
  assert.deepEqual(mergeHistory([], []), []);
  assert.deepEqual(mergeHistory(["a", " ", "a"], []), ["a"]);
});

test("stepHistory and entryAt walk newest-first and clamp at both ends", () => {
  const list = ["first", "second", "third"];
  let i = -1;
  i = stepHistory(list.length, i, "up");
  assert.equal(entryAt(list, i), "third");
  i = stepHistory(list.length, i, "up");
  assert.equal(entryAt(list, i), "second");
  i = stepHistory(list.length, i, "up");
  i = stepHistory(list.length, i, "up");
  assert.equal(i, 2);
  assert.equal(entryAt(list, i), "first");
  i = stepHistory(list.length, i, "down");
  i = stepHistory(list.length, i, "down");
  i = stepHistory(list.length, i, "down");
  assert.equal(i, -1);
  assert.equal(entryAt(list, i), null);
  assert.equal(stepHistory(0, -1, "up"), -1);
});

test("historyKeyIntent only fires from the first line (up) or last line (down)", () => {
  assert.equal(historyKeyIntent("", 0, "ArrowUp"), "up");
  assert.equal(historyKeyIntent("one line", 3, "ArrowUp"), "up");
  assert.equal(historyKeyIntent("one line", 3, "ArrowDown"), "down");
  assert.equal(historyKeyIntent("two\nlines", 6, "ArrowUp"), null);
  assert.equal(historyKeyIntent("two\nlines", 6, "ArrowDown"), "down");
  assert.equal(historyKeyIntent("two\nlines", 1, "ArrowDown"), null);
  assert.equal(historyKeyIntent("two\nlines", 1, "ArrowUp"), "up");
  assert.equal(historyKeyIntent("x", 1, "Enter"), null);
});

test("loadHistory and saveHistory round-trip through a storage-like object and tolerate garbage", () => {
  const store = new Map<string, string>();
  const storage = {
    getItem: (key: string) => store.get(key) ?? null,
    setItem: (key: string, value: string) => void store.set(key, value),
  };
  saveHistory(storage, ["a", "b"]);
  assert.deepEqual(loadHistory(storage), ["a", "b"]);
  assert.equal(store.has(HISTORY_KEY), true);
  store.set(HISTORY_KEY, "not json");
  assert.deepEqual(loadHistory(storage), []);
  store.set(HISTORY_KEY, JSON.stringify(["ok", 7, null]));
  assert.deepEqual(loadHistory(storage), ["ok"]);
  assert.deepEqual(loadHistory(null), []);
  assert.doesNotThrow(() => saveHistory(null, ["x"]));
  assert.doesNotThrow(() =>
    saveHistory(
      {
        setItem: () => {
          throw new Error("quota");
        },
      },
      ["x"],
    ),
  );
});
