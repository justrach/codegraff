import { describe, expect, test } from "bun:test";

import type { Attachment } from "./attachmentTypes";
import {
  appendAttachmentsToPrompt,
  classifyPath,
  parseAttachmentBlock,
} from "./attachmentTypes";

function attachmentFixture(path: string): Attachment {
  return {
    id: path,
    path,
    name: path.split("/").pop() ?? path,
    ext: "pdf",
    kind: "pdf",
  };
}

describe("appendAttachmentsToPrompt", () => {
  test("returns the prompt unchanged when there are no attachments", () => {
    expect(appendAttachmentsToPrompt("summarise", [])).toBe("summarise");
  });

  test("appends attachments as harness @[path] tokens", () => {
    const result = appendAttachmentsToPrompt("summarise", [
      attachmentFixture("/abs/CanvasPilot-README.pdf"),
    ]);

    expect(result).toBe(
      "summarise\n\nAttached files:\n@[/abs/CanvasPilot-README.pdf]",
    );
  });
});

describe("round-trip", () => {
  test("parseAttachmentBlock recovers the body and original paths", () => {
    const body = "summarise these";
    const paths = ["/abs/CanvasPilot-README.pdf", "/abs/notes with space.md"];
    const attachments = paths.map(attachmentFixture);

    const combined = appendAttachmentsToPrompt(body, attachments);
    const parsed = parseAttachmentBlock(combined);

    expect(parsed.body).toBe(body);
    expect(parsed.paths).toEqual(paths);
  });

  test("messages without an attachment block are left intact", () => {
    const parsed = parseAttachmentBlock("just a normal message");
    expect(parsed.body).toBe("just a normal message");
    expect(parsed.paths).toEqual([]);
  });
});

// Regression guard for #78: navigating prompt history restored a sent prompt as
// raw `Attached files:` text and dropped the image card. The history handler now
// runs this exact pipeline — parseAttachmentBlock → classifyPath → rehydrate tray.
describe("prompt-history restore pipeline (#78)", () => {
  test("splits a sent prompt back into body + a restorable image attachment", () => {
    const sent = appendAttachmentsToPrompt("describe this", [
      { id: "/x/shot.png", path: "/x/shot.png", name: "shot.png", ext: "png", kind: "image" },
    ]);

    const { body, paths } = parseAttachmentBlock(sent);
    expect(body).toBe("describe this");
    expect(paths).toEqual(["/x/shot.png"]);

    const restored = paths
      .map((p) => classifyPath(p))
      .filter((a): a is NonNullable<typeof a> => a != null);
    expect(restored).toHaveLength(1);
    expect(restored[0]?.kind).toBe("image");
    expect(restored[0]?.name).toBe("shot.png");
  });

  test("a text-only history entry restores no attachments", () => {
    const { body, paths } = parseAttachmentBlock("just a question");
    expect(body).toBe("just a question");
    expect(paths).toEqual([]);
  });
});
