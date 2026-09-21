import { test } from "node:test";
import assert from "node:assert/strict";
import { attachRowKeepsUserActivation, filesFrom, isImageFile, liftAttachmentMarkers, marker, markerName, splitImageMarkers, uploadAttachment, withAttachmentMarkers, type Attachment } from "./attachments.ts";

const shot: Attachment = { id: "/tmp/a/shot.png", name: "shot.png", path: "/tmp/a/shot.png" };
const notes: Attachment = { id: "/tmp/a/notes.md", name: "notes.md", path: "/tmp/a/notes.md" };

test("markers are the @[path] form the harness stages vision blocks from", () => {
  assert.equal(marker(shot), "@[/tmp/a/shot.png]");
});

test("withAttachmentMarkers appends one marker per attachment", () => {
  assert.equal(withAttachmentMarkers("look at this", [shot]), "look at this @[/tmp/a/shot.png]");
  assert.equal(
    withAttachmentMarkers("compare", [shot, notes]),
    "compare @[/tmp/a/shot.png] @[/tmp/a/notes.md]",
  );
});

test("an attachment the draft already names is not sent twice", () => {
  assert.equal(withAttachmentMarkers("see @[/tmp/a/shot.png] here", [shot]), "see @[/tmp/a/shot.png] here");
});

test("a draft with no attachments, and attachments with no draft, both survive", () => {
  assert.equal(withAttachmentMarkers("just words", []), "just words");
  assert.equal(withAttachmentMarkers("", [shot]), "@[/tmp/a/shot.png]");
  assert.equal(withAttachmentMarkers("   ", []), "   ");
});

test("splitImageMarkers lifts a staged image out of the words around it", () => {
  const staged = "@[/tmp/x/graff-native-attachments/shot.png]";
  assert.deepEqual(splitImageMarkers(`look at this ${staged} please`), ["look at this ", staged, " please"]);
  assert.deepEqual(splitImageMarkers("no images here"), ["no images here"]);
  assert.deepEqual(splitImageMarkers(staged), ["", staged, ""]);
});

test("only the staged attachment directory previews; any other path stays text", () => {
  assert.deepEqual(splitImageMarkers("@[/tmp/a/shot.png]"), ["@[/tmp/a/shot.png]"]);
  assert.deepEqual(splitImageMarkers("@[/tmp/x/graff-native-attachments/notes.md]"), ["@[/tmp/x/graff-native-attachments/notes.md]"]);
});

test("liftAttachmentMarkers turns staged image tokens into chips", () => {
  const staged = "@[/tmp/x/graff-native-attachments/shot.png]";
  const lifted = liftAttachmentMarkers(`look at this ${staged} please`);
  assert.equal(lifted.text, "look at this please");
  assert.equal(lifted.attachments.length, 1);
  assert.equal(lifted.attachments[0]?.name, "shot.png");
  assert.equal(lifted.attachments[0]?.path, "/tmp/x/graff-native-attachments/shot.png");
  assert.deepEqual(liftAttachmentMarkers("no images here"), { text: "no images here", attachments: [] });
});

test("markerName is the basename /api/attach answers to", () => {
  assert.equal(markerName("@[/tmp/x/graff-native-attachments/shot.png]"), "shot.png");
});

test("isImageFile follows the media type, which is what decides the chip", () => {
  assert.equal(isImageFile(new File([], "a.png", { type: "image/png" })), true);
  assert.equal(isImageFile(new File([], "a.md", { type: "text/markdown" })), false);
  assert.equal(isImageFile(new File([], "a.png")), false);
});

test("filesFrom reads a paste's items, and falls back to files on a drop", () => {
  const png = new File([], "shot.png", { type: "image/png" });
  const pasted = {
    items: [
      { kind: "string", getAsFile: () => null },
      { kind: "file", getAsFile: () => png },
    ],
    files: [],
  } as unknown as DataTransfer;
  assert.deepEqual(filesFrom(pasted), [png]);

  const dropped = { items: [], files: [png] } as unknown as DataTransfer;
  assert.deepEqual(filesFrom(dropped), [png]);
});

test("a paste carrying only text yields nothing, so the composer lets it through", () => {
  const textOnly = {
    items: [{ kind: "string", getAsFile: () => null }],
    files: [],
  } as unknown as DataTransfer;
  assert.deepEqual(filesFrom(textOnly), []);
  assert.deepEqual(filesFrom(null), []);
});

test("the attach row keeps the pointer gesture so the file dialog can open", () => {
  assert.equal(attachRowKeepsUserActivation("attach"), true);
  assert.equal(attachRowKeepsUserActivation("file:notes.md"), false);
});

function hangUntilAbort(signal?: AbortSignal): Promise<never> {
  if (!signal) return Promise.reject(new Error("expected abort signal"));
  return new Promise((_, reject) => {
    const fail = () => reject(signal.reason ?? new DOMException("The operation was aborted.", "TimeoutError"));
    if (signal.aborted) {
      fail();
      return;
    }
    signal.addEventListener("abort", fail, { once: true });
  });
}

function okAttach(name: string): Response {
  return Response.json({ path: `/tmp/x/${name}`, name });
}

test("uploadAttachment times out instead of hanging the composer", async () => {
  const file = new File([new Uint8Array([1])], "shot.png", { type: "image/png" });
  const original = globalThis.fetch;
  globalThis.fetch = (async (_url: unknown, init?: { signal?: AbortSignal }) => hangUntilAbort(init?.signal)) as typeof fetch;
  try {
    await assert.rejects(() => uploadAttachment(file, 15), /Adding shot\.png timed out/);
  } finally {
    globalThis.fetch = original;
  }
});

test("a hung first upload does not block a later file from completing", async () => {
  const hung = new File([new Uint8Array([1])], "stuck.png", { type: "image/png" });
  const later = new File([new Uint8Array([1])], "ok.png", { type: "image/png" });
  const original = globalThis.fetch;
  let calls = 0;
  globalThis.fetch = (async (_url: unknown, init?: { signal?: AbortSignal }) => {
    calls += 1;
    if (calls === 1) return hangUntilAbort(init?.signal);
    return okAttach("ok.png");
  }) as typeof fetch;
  try {
    const pendingHung = uploadAttachment(hung, 80);
    const finished = await uploadAttachment(later, 80);
    assert.equal(finished.name, "ok.png");
    await assert.rejects(pendingHung, /Adding stuck\.png timed out/);
  } finally {
    globalThis.fetch = original;
  }
});

test("partial multi-file failure names the failed file and keeps the successful one", async () => {
  const bad = new File([new Uint8Array([1])], "notes.md", { type: "text/markdown" });
  const good = new File([new Uint8Array([1])], "shot.png", { type: "image/png" });
  const original = globalThis.fetch;
  let calls = 0;
  globalThis.fetch = (async () => {
    calls += 1;
    if (calls === 1) return Response.json({ error: "not stored" }, { status: 500 });
    return okAttach("shot.png");
  }) as typeof fetch;
  try {
    const results = await Promise.allSettled([uploadAttachment(bad, 80), uploadAttachment(good, 80)]);
    assert.equal(results[0]?.status, "rejected");
    assert.match((results[0] as PromiseRejectedResult).reason.message, /notes\.md/);
    assert.equal(results[1]?.status, "fulfilled");
    assert.equal((results[1] as PromiseFulfilledResult<{ name: string }>).value.name, "shot.png");
  } finally {
    globalThis.fetch = original;
  }
});
