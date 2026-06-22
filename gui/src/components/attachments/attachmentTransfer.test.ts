import { describe, expect, test } from "bun:test";

import {
  dataTransferHasAttachmentPayload,
  extractAttachmentTransferItems,
  filterSupportedAttachmentTransferItems,
  getAttachmentTransferFileName,
  normalizeFileTransferPath,
  type DataTransferLike,
} from "./attachmentTransfer";

function transfer(input: Partial<DataTransferLike>): DataTransferLike {
  return {
    files: [],
    items: [],
    types: [],
    getData: () => "",
    ...input,
  };
}

describe("attachment transfer extraction", () => {
  test("extracts browser File objects from DataTransfer.files", () => {
    const file = new File(["hello"], "notes.md", { type: "text/markdown" });
    const dataTransfer = transfer({
      files: [file],
      types: ["Files"],
    });

    expect(dataTransferHasAttachmentPayload(dataTransfer)).toBe(true);
    expect(extractAttachmentTransferItems(dataTransfer)).toEqual([
      { kind: "file", file },
    ]);
  });

  test("extracts browser File objects from clipboard items", () => {
    const file = new File(["hello"], "clip.png", { type: "image/png" });
    const dataTransfer = transfer({
      items: [
        {
          kind: "file",
          type: "image/png",
          getAsFile: () => file,
        },
      ],
    });

    expect(extractAttachmentTransferItems(dataTransfer)).toEqual([
      { kind: "file", file },
    ]);
  });

  test("normalizes file URLs and absolute path text into path attachments", () => {
    const dataTransfer = transfer({
      types: ["text/uri-list"],
      getData: (format) =>
        format === "text/uri-list"
          ? "# Finder file\nfile:///Users/me/notes%20with%20space.pdf"
          : "",
    });

    expect(normalizeFileTransferPath("file:///Users/me/a%20b.txt")).toBe(
      "/Users/me/a b.txt",
    );
    expect(extractAttachmentTransferItems(dataTransfer)).toEqual([
      { kind: "path", path: "/Users/me/notes with space.pdf" },
    ]);
  });

  test("ignores ordinary text paste/drop payloads", () => {
    const dataTransfer = transfer({
      types: ["text/plain"],
      getData: () => "hello, this is just prose",
    });

    expect(dataTransferHasAttachmentPayload(dataTransfer)).toBe(false);
    expect(extractAttachmentTransferItems(dataTransfer)).toEqual([]);
  });

  test("filters unsupported file extensions before saving", () => {
    const file = new File(["binary"], "installer.exe", {
      type: "application/octet-stream",
    });
    const dataTransfer = transfer({
      files: [file],
      types: ["Files"],
    });

    expect(getAttachmentTransferFileName(file)).toBe("installer.exe");
    expect(
      filterSupportedAttachmentTransferItems(
        extractAttachmentTransferItems(dataTransfer),
      ),
    ).toEqual([]);
  });

  test("ignores internal chat binding drags", () => {
    const dataTransfer = transfer({
      types: ["application/x-codegraff-chat-binding", "text/plain"],
      getData: () =>
        '{"workspacePath":"/workspace/codegraff","conversationId":"chat-1"}',
    });

    expect(dataTransferHasAttachmentPayload(dataTransfer)).toBe(false);
    expect(extractAttachmentTransferItems(dataTransfer)).toEqual([]);
  });
});
