import { expect, test } from "bun:test";
import { createModelSwitcher } from "../components/site/harness-model";
import type { Chat } from "../components/site/harness-types";

function fixture(wait?: () => Promise<void>) {
  const chatsRef = { current: [1, 2].map(id => ({ id, title: null, messages: [], model: "old" })) as Chat[] };
  const runningRef = { current: new Set([1, 2]) };
  const resets: unknown[][] = [];
  let fail = false;
  const switcher = createModelSwitcher({
    chatsRef, runningRef, pendingPickRef: { current: null }, activeChatId: () => 1,
    requireSession: async (...args) => { resets.push(args); await wait?.(); if (fail) throw Error("restart failed"); return "session"; },
    setChatModel: (id, key) => { chatsRef.current = chatsRef.current.map(chat => chat.id === id ? { ...chat, model: key } : chat); },
    setChats: update => { chatsRef.current = typeof update === "function" ? update(chatsRef.current) : update; },
    setCancelError: () => {}, setPendingModel: () => { throw Error("A running choice must not open the restart dialog"); },
  });
  return { ...switcher, chatsRef, resets, runningRef, fail: () => { fail = true; } };
}

test("running model choices stage independently and apply only at each next prompt boundary", async () => {
  const f = fixture();
  f.changeModel("next-a", 1); f.changeModel("next-b", 2); f.changeModel("latest-a", 1);
  expect(f.resets).toEqual([]);
  expect(f.chatsRef.current.map(chat => chat.model)).toEqual(["old", "old"]);
  expect(f.chatsRef.current.map(chat => chat.nextModel)).toEqual(["latest-a", "next-b"]);
  await f.prepareModel(1);
  expect(f.resets).toEqual([[1, true, "latest-a"]]);
  expect(f.chatsRef.current[0]).toMatchObject({ model: "latest-a", nextModel: undefined });
  expect(f.chatsRef.current[1]).toMatchObject({ model: "old", nextModel: "next-b" });
  await f.prepareModel(1);
  expect(f.resets).toHaveLength(1);
});

test("selecting the current model cancels a staged choice without touching the worker", async () => {
  const f = fixture();
  f.changeModel("next", 1); f.changeModel("old", 1);
  await f.prepareModel(1);
  expect(f.resets).toEqual([]);
  expect(f.chatsRef.current[0].nextModel).toBeUndefined();
});

test("failed next-model startup retains the requested choice for retry", async () => {
  const f = fixture();
  f.changeModel("next", 1); f.fail();
  await expect(f.prepareModel(1)).rejects.toThrow("restart failed");
  expect(f.chatsRef.current[0]).toMatchObject({ model: "old", nextModel: "next" });
});


test("choosing the original model during next-model startup preserves the newer request", async () => {
  let ready!: () => void;
  const wait = new Promise<void>(resolve => { ready = resolve; });
  const f = fixture(() => wait);
  f.changeModel("next", 1);
  const preparing = f.prepareModel(1);
  f.changeModel("old", 1);
  ready(); await preparing;
  expect(f.chatsRef.current[0]).toMatchObject({ model: "next", nextModel: "old", preparingModel: undefined });
  await f.prepareModel(1);
  expect(f.resets).toEqual([[1, true, "next"], [1, true, "old"]]);
});
