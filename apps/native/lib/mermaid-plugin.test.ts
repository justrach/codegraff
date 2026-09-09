import { describe, it } from "node:test";
import assert from "node:assert/strict";
import { mermaid } from "@streamdown/mermaid";

describe("mermaid plugin", () => {
  it("claims mermaid fences as diagrams", () => {
    assert.equal(mermaid.name, "mermaid");
    assert.equal(mermaid.type, "diagram");
    assert.equal(mermaid.language, "mermaid");
  });
});
