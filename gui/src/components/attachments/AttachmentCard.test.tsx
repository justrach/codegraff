import { describe, expect, test } from "bun:test";
import { renderToStaticMarkup } from "react-dom/server";

import { AttachmentCard } from "./AttachmentCard";
import type { Attachment } from "./attachmentTypes";

const attachment: Attachment = {
  ext: "pdf",
  id: "attachment-1",
  kind: "pdf",
  name: "Design Notes.pdf",
  path: "/workspace/Design Notes.pdf",
};

describe("AttachmentCard", () => {
  test("shows the remove control on keyboard focus", () => {
    const html = renderToStaticMarkup(
      <AttachmentCard attachment={attachment} onRemove={() => {}} />,
    );

    expect(html).toContain("focus-visible:opacity-100");
    expect(html).toContain("group-focus-within/attachment:opacity-100");
    expect(html).toContain("Remove Design Notes.pdf");
  });
});
