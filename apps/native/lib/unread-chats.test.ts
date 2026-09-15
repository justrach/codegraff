import { expect, test } from "bun:test";
import { completedUnread } from "../components/site/useUnreadChats";
import { sidebarRecents } from "../components/site/harness-sidebar";

test("background completion is unread until its pane is viewed", () => {
  const unread = completedUnread(new Set(), 1, [2], [1, 2]);
  expect([...unread]).toEqual([1]);
  expect([...completedUnread(unread, -1, [1], [1, 2])]).toEqual([]);
});

test("visible split completions and closed chats do not become unread", () => {
  expect(completedUnread(new Set(), 1, [1, 2], [1, 2]).size).toBe(0);
  expect(completedUnread(new Set(), 1, [], [2]).size).toBe(0);
});

test("sidebar consumes the same unread identity as the chat", () => {
  const saved = { name: "saved", title: "Check", updatedMs: 1, model: null, provider: null, size: 1, workspace: "/fixture" };
  const chats = [{ id: 1, title: "Check", messages: [], session: "saved", cwd: "/fixture" }];
  expect(sidebarRecents([saved], chats, new Set([1]))[0].unread).toBe(true);
  expect(sidebarRecents([saved], chats, new Set())[0].unread).toBe(false);
  expect(sidebarRecents([{ ...saved, local: true, workspace: "/another" }], chats, new Set([1]))[0].unread).toBe(true);
  expect(sidebarRecents([{ ...saved, workspace: "/another" }], chats, new Set([1]))[0].unread).toBe(false);
});
