import { afterEach, expect, test } from "bun:test";

import { getAttachments, resetSessionStore, sessionStore } from "./sessionStore";

afterEach(resetSessionStore);

test("attachment replacement removes the previous history entry atomically", () => {
  const key = "conversation:history-attachments";
  const previous = {
    id: "/abs/previous.png",
    path: "/abs/previous.png",
    name: "previous.png",
    ext: "png",
    kind: "image" as const,
  };
  const next = [
    {
      id: "/abs/next-a.png",
      path: "/abs/next-a.png",
      name: "next-a.png",
      ext: "png",
      kind: "image" as const,
    },
    {
      id: "/abs/next-b.png",
      path: "/abs/next-b.png",
      name: "next-b.png",
      ext: "png",
      kind: "image" as const,
    },
  ];

  sessionStore.getState().addAttachments(key, [previous]);
  const replacementNotifications: string[][] = [];
  const unsubscribe = sessionStore.subscribe((current, prior) => {
    if (current.attachmentsByKey[key] !== prior.attachmentsByKey[key]) {
      replacementNotifications.push(
        (current.attachmentsByKey[key] ?? []).map((item) => item.path),
      );
    }
  });

  sessionStore.getState().replaceAttachments(key, next);
  unsubscribe();

  expect(replacementNotifications).toEqual([
    next.map((item) => item.path),
  ]);
  expect(getAttachments(key)).toEqual(next);
  expect(getAttachments(key)).not.toContainEqual(previous);

  sessionStore.getState().replaceAttachments(key, []);
  expect(getAttachments(key)).toEqual([]);
  expect(sessionStore.getState().attachmentsByKey[key]).toBeUndefined();
});
