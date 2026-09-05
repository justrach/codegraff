import { test } from "node:test";
import assert from "node:assert/strict";
import { filesFrom, isImageFile, marker, withAttachmentMarkers, type Attachment } from "./attachments.ts";

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
