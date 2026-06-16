import { describe, expect, test } from "bun:test";

import type { Attachment } from "./attachmentTypes";
import {
  appendAttachmentsToPrompt,
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
