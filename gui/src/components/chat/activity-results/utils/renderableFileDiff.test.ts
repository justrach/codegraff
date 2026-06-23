import { describe, expect, test } from "bun:test";

import { parseByteCount, resolveRenderableFileDiff } from "./renderableFileDiff";

describe("renderableFileDiff", () => {
  test("parses byte summaries with thousands separators", () => {
    expect(parseByteCount("wrote 201,337 bytes to generated.ts")).toBe(201_337);
  });

  test("keeps large create/overwrite summaries as placeholders instead of reading and synthesizing huge diffs", async () => {
    let readCalled = false;
    const resolved = await resolveRenderableFileDiff({
      workspacePath: "/workspace",
      path: "generated.ts",
      patch: "wrote 201,337 bytes to generated.ts",
      operation: "create",
      readFile: async () => {
        readCalled = true;
        throw new Error("large create should not be read");
      },
    });

    expect(readCalled).toBe(false);
    expect(resolved).toEqual({
      status: "placeholder",
      operation: "create",
      byteCount: 201_337,
    });
  });
});
