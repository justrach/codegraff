import { describe, expect, test } from "bun:test";

import {
  buildRenderableFileDiffPatch,
  getFileDiffPatchStats,
} from "./fileDiff";

describe("fileDiff", () => {
  test("converts excerpt-style file diffs into unified git patches", () => {
    const patch = buildRenderableFileDiffPatch(
      "src/example.ts",
      ["1 1 | const before = true;", "2   |-removed();", "  2 |+added();"].join(
        "\n",
      ),
    );

    expect(patch).toContain("diff --git a/src/example.ts b/src/example.ts");
    expect(patch).toContain("@@ -1,2 +1,2 @@");
    expect(patch).toContain(" const before = true;");
    expect(patch).toContain("-removed();");
    expect(patch).toContain("+added();");
    expect(getFileDiffPatchStats(patch)).toEqual({ additions: 1, deletions: 1 });
  });

  test("keeps existing unified patches unchanged", () => {
    const patch = [
      "diff --git a/src/example.ts b/src/example.ts",
      "--- a/src/example.ts",
      "+++ b/src/example.ts",
      "@@ -1,1 +1,1 @@",
      "-old();",
      "+next();",
    ].join("\n");

    expect(buildRenderableFileDiffPatch("src/example.ts", patch)).toBe(patch);
    expect(getFileDiffPatchStats(patch)).toEqual({ additions: 1, deletions: 1 });
  });
});
