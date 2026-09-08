import { expect, test } from "bun:test";
import { createComposerDraft } from "./composer-draft";

test("a hidden chat retains text and receives its pending upload without changing another chat", () => {
  const first = createComposerDraft(), second = createComposerDraft();
  first.setDraft("First draft"); first.setUploads(1);
  second.setDraft("Second draft");
  const upload = { id: "file", path: "/demo/image.png", name: "image.png" };
  first.setAttachments(current => [...current, upload]); first.setUploads(count => count - 1);
  expect(first.getSnapshot()).toEqual({ draft: "First draft", attachments: [upload], uploads: 0, attachError: null });
  expect(second.getSnapshot().draft).toBe("Second draft");
  expect(second.getSnapshot().attachments).toEqual([]);
});

test("closing a chat releases previews including an upload that completes after disposal", () => {
  const released: string[] = [];
  const store = createComposerDraft(files => released.push(...files.map(file => file.id)));
  store.setAttachments([{ id: "first", name: "first.png", path: "/demo/first.png", preview: "blob:first" }]);
  store.dispose(); store.dispose();
  store.setAttachments(current => [...current, { id: "late", name: "late.png", path: "/demo/late.png", preview: "blob:late" }]);
  store.setDraft("late update");
  expect(released).toEqual(["first", "late"]);
  expect(store.getSnapshot().attachments).toEqual([]);
  expect(store.getSnapshot().draft).toBe("");
});
